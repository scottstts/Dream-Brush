# Copyright 2022 The Nerfstudio Team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Data manager that outputs cameras / images instead of raybundles

Good for things like gaussian splatting which require full cameras instead of the standard ray
paradigm
"""

from __future__ import annotations

import random
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from dataclasses import dataclass, field
from functools import cached_property
import os
from pathlib import Path
from typing import Dict, ForwardRef, Generic, List, Literal, Optional, Tuple, Type, Union, cast, get_args, get_origin

import cv2
import fpsample
import numpy as np
import torch
from rich.progress import track
from torch.nn import Parameter
from typing_extensions import assert_never

from nerfstudio.cameras.camera_utils import fisheye624_project, fisheye624_unproject_helper
from nerfstudio.cameras.cameras import Cameras, CameraType
from nerfstudio.configs.dataparser_configs import AnnotatedDataParserUnion
from nerfstudio.data.datamanagers.base_datamanager import DataManager, DataManagerConfig, TDataset
from nerfstudio.data.dataparsers.base_dataparser import DataparserOutputs
from nerfstudio.data.dataparsers.nerfstudio_dataparser import NerfstudioDataParserConfig
from nerfstudio.data.datasets.base_dataset import InputDataset
from nerfstudio.utils.misc import get_orig_class
from nerfstudio.utils.rich_utils import CONSOLE


@dataclass
class FullImageDatamanagerConfig(DataManagerConfig):
    _target: Type = field(default_factory=lambda: FullImageDatamanager)
    dataparser: AnnotatedDataParserUnion = field(default_factory=NerfstudioDataParserConfig)
    camera_res_scale_factor: float = 1.0
    """The scale factor for scaling spatial data such as images, mask, semantics
    along with relevant information about camera intrinsics
    """
    eval_num_images_to_sample_from: int = -1
    """Number of images to sample during eval iteration."""
    eval_num_times_to_repeat_images: int = -1
    """When not evaluating on all images, number of iterations before picking
    new images. If -1, never pick new images."""
    eval_image_indices: Optional[Tuple[int, ...]] = (0,)
    """Specifies the image indices to use during eval; if None, uses all."""
    cache_images: Literal["cpu", "gpu", "lazy", "auto"] = "auto"
    """Whether to cache images in memory. If "lazy", load per-image on demand."""
    cache_images_type: Literal["uint8", "float32"] = "float32"
    """The image type returned from manager, caching images in uint8 saves memory"""
    allow_large_gpu_cache: bool = False
    """If True, do not override GPU caching for datasets over 500 images."""
    gpu_cache_max_fraction: float = 0.6
    """Max fraction of total GPU memory to use for cached images before falling back to CPU."""
    max_thread_workers: Optional[int] = None
    """The maximum number of threads to use for caching images. If None, uses all available threads."""
    non_blocking_transfers: bool = True
    """Use non-blocking transfers when moving pinned CPU tensors to GPU."""
    prefetch_to_gpu: bool = True
    """If True, prefetch the next batch to GPU using a dedicated CUDA stream (when caching on CPU)."""
    cv2_num_threads: Optional[int] = None
    """Optional override for OpenCV internal thread count."""
    cv2_use_optimized: bool = True
    """Enable OpenCV optimizations if available."""
    preprocessed_data: bool = False
    """If True, assume images are already undistorted/resized and skip eager caching by default."""
    depth_resize_mode: Literal["image", "native", "max_edge"] = "native"
    """How to resize depth/confidence before caching. 'native' keeps sensor resolution."""
    depth_max_edge: int = 480
    """If depth_resize_mode is 'max_edge', cap the longest edge to this many pixels."""
    depth_dtype: Literal["float32", "float16"] = "float16"
    """Depth dtype when cached in memory."""
    confidence_dtype: Literal["float32", "float16", "uint8"] = "uint8"
    """Confidence dtype when cached in memory."""
    train_cameras_sampling_strategy: Literal["random", "fps"] = "random"
    """Specifies which sampling strategy is used to generate train cameras, 'random' means sampling 
    uniformly random without replacement, 'fps' means farthest point sampling which is helpful to reduce the artifacts 
    due to oversampling subsets of cameras that are very close to each other."""
    train_cameras_sampling_seed: int = 42
    """Random seed for sampling train cameras. Fixing seed may help reduce variance of trained models across 
    different runs."""
    fps_reset_every: int = 100
    """The number of iterations before one resets fps sampler repeatly, which is essentially drawing fps_reset_every
    samples from the pool of all training cameras without replacement before a new round of sampling starts."""


class FullImageDatamanager(DataManager, Generic[TDataset]):
    """
    A datamanager that outputs full images and cameras instead of raybundles. This makes the
    datamanager more lightweight since we don't have to do generate rays. Useful for full-image
    training e.g. rasterization pipelines
    """

    config: FullImageDatamanagerConfig
    train_dataset: TDataset
    eval_dataset: TDataset

    def __init__(
        self,
        config: FullImageDatamanagerConfig,
        device: Union[torch.device, str] = "cpu",
        test_mode: Literal["test", "val", "inference"] = "val",
        world_size: int = 1,
        local_rank: int = 0,
        **kwargs,
    ):
        self.config = config
        self.device = device
        self.world_size = world_size
        self.local_rank = local_rank
        self.sampler = None
        self.test_mode = test_mode
        self.test_split = "test" if test_mode in ["test", "inference"] else "val"
        self.dataparser_config = self.config.dataparser
        if self.config.data is not None:
            self.config.dataparser.data = Path(self.config.data)
        else:
            self.config.data = self.config.dataparser.data
        self.dataparser = self.dataparser_config.setup()
        if test_mode == "inference":
            self.dataparser.downscale_factor = 1  # Avoid opening images
        self.includes_time = self.dataparser.includes_time

        if self.config.cv2_use_optimized:
            cv2.setUseOptimized(True)
        if self.config.cv2_num_threads is not None:
            cv2.setNumThreads(self.config.cv2_num_threads)

        self.train_dataparser_outputs: DataparserOutputs = self.dataparser.get_dataparser_outputs(split="train")
        self.train_dataset = self.create_train_dataset()
        self.eval_dataset = self.create_eval_dataset()
        self._lazy_train_cache: Dict[int, Dict[str, torch.Tensor]] = {}
        self._lazy_eval_cache: Dict[int, Dict[str, torch.Tensor]] = {}
        self.train_depth_filenames = self.train_dataparser_outputs.metadata.get("depth_filenames")
        self.train_confidence_filenames = self.train_dataparser_outputs.metadata.get("confidence_filenames")
        self.train_depth_unit_scale = self.train_dataparser_outputs.metadata.get("depth_unit_scale_factor", 1.0)
        self.train_depth_scale = self.train_dataparser_outputs.dataparser_scale

        eval_outputs = self.dataparser.get_dataparser_outputs(split=self.test_split)
        self.eval_depth_filenames = eval_outputs.metadata.get("depth_filenames")
        self.eval_confidence_filenames = eval_outputs.metadata.get("confidence_filenames")
        self.eval_depth_unit_scale = eval_outputs.metadata.get("depth_unit_scale_factor", 1.0)
        self.eval_depth_scale = eval_outputs.dataparser_scale

        if self.config.preprocessed_data and self.config.cache_images == "auto":
            self.config.cache_images = "lazy"
        self.config.cache_images = self._select_cache_images_device()

        self.exclude_batch_keys_from_device = self.train_dataset.exclude_batch_keys_from_device
        if self.config.masks_on_gpu is True:
            self.exclude_batch_keys_from_device.remove("mask")
        if self.config.images_on_gpu is True:
            self.exclude_batch_keys_from_device.remove("image")

        # Some logic to make sure we sample every camera in equal amounts
        self.train_unseen_cameras = self.sample_train_cameras()
        self.eval_unseen_cameras = [i for i in range(len(self.eval_dataset))]
        assert len(self.train_unseen_cameras) > 0, "No data found in dataset"

        if self.config.cache_images == "lazy":
            self.train_cameras = self.train_dataset.cameras

        self._prefetch_stream: Optional[torch.cuda.Stream] = None
        self._prefetch_train: Optional[Tuple[Cameras, Dict]] = None
        self._prefetch_train_idx: Optional[int] = None
        if (
            self.config.prefetch_to_gpu
            and self.config.cache_images in ("cpu", "lazy")
            and torch.cuda.is_available()
            and torch.device(self.device).type == "cuda"
        ):
            self._prefetch_stream = torch.cuda.Stream(device=self.device)

        super().__init__()

    def _select_cache_images_device(self) -> Literal["cpu", "gpu", "lazy"]:
        requested = self.config.cache_images
        if requested == "lazy":
            return "lazy"

        if requested == "auto":
            requested = "gpu"

        if requested == "gpu":
            if not torch.cuda.is_available() or torch.device(self.device).type != "cuda":
                CONSOLE.log("[yellow]cache_images='gpu' but CUDA is unavailable; using cpu.")
                return "cpu"
            if len(self.train_dataset) > 500 and not self.config.allow_large_gpu_cache:
                CONSOLE.print(
                    "Train dataset has over 500 images, overriding cache_images to cpu",
                    style="bold yellow",
                )
                return "cpu"
            est_bytes = self._estimate_cache_bytes("train")
            if est_bytes is not None:
                free_bytes, total_bytes = torch.cuda.mem_get_info(self.device)
                limit = int(total_bytes * float(self.config.gpu_cache_max_fraction))
                limit = min(limit, int(free_bytes * float(self.config.gpu_cache_max_fraction)))
                if est_bytes > limit:
                    CONSOLE.print(
                        f"[yellow]Estimated GPU cache size {est_bytes / (1024**3):.2f} GiB exceeds "
                        f"limit {limit / (1024**3):.2f} GiB; using cpu cache instead."
                    )
                    return "cpu"
            return "gpu"

        return "cpu"

    def _estimate_cache_bytes(self, split: Literal["train", "eval"]) -> Optional[int]:
        dataset = self.train_dataset if split == "train" else self.eval_dataset
        if len(dataset) == 0:
            return None
        try:
            image_h = int(dataset.cameras.height[0].item())
            image_w = int(dataset.cameras.width[0].item())
        except Exception:
            return None

        if self.config.cache_images_type == "float32":
            image_bytes = 4
        else:
            image_bytes = 1
        image_total = len(dataset) * image_h * image_w * 3 * image_bytes

        depth_filenames = self.train_depth_filenames if split == "train" else self.eval_depth_filenames
        confidence_filenames = self.train_confidence_filenames if split == "train" else self.eval_confidence_filenames

        depth_total = 0
        confidence_total = 0
        if depth_filenames:
            depth_h, depth_w = self._estimate_depth_shape(depth_filenames, image_h, image_w)
            depth_bytes = 2 if self.config.depth_dtype == "float16" else 4
            depth_total = len(depth_filenames) * depth_h * depth_w * depth_bytes
        if confidence_filenames:
            conf_h, conf_w = self._estimate_depth_shape(confidence_filenames, image_h, image_w)
            if self.config.confidence_dtype == "uint8":
                conf_bytes = 1
            elif self.config.confidence_dtype == "float16":
                conf_bytes = 2
            else:
                conf_bytes = 4
            confidence_total = len(confidence_filenames) * conf_h * conf_w * conf_bytes

        total = int((image_total + depth_total + confidence_total) * 1.05)  # safety margin
        return total

    def _estimate_depth_shape(self, filenames: List[Path], image_h: int, image_w: int) -> Tuple[int, int]:
        source_h, source_w = image_h, image_w
        for path in filenames:
            if path and Path(path).exists():
                depth_raw = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
                if depth_raw is not None:
                    source_h, source_w = depth_raw.shape[:2]
                    break

        mode = self.config.depth_resize_mode
        if mode == "image":
            return image_h, image_w
        if mode == "native":
            return source_h, source_w
        if mode == "max_edge":
            max_edge = max(1, int(self.config.depth_max_edge))
            max_source = max(source_h, source_w)
            if max_source <= max_edge:
                return source_h, source_w
            scale = max_edge / float(max_source)
            target_h = max(1, int(round(source_h * scale)))
            target_w = max(1, int(round(source_w * scale)))
            return target_h, target_w
        assert_never(mode)

    def sample_train_cameras(self):
        """Return a list of camera indices sampled using the strategy specified by
        self.config.train_cameras_sampling_strategy"""
        num_train_cameras = len(self.train_dataset)
        if self.config.train_cameras_sampling_strategy == "random":
            if not hasattr(self, "random_generator"):
                self.random_generator = random.Random(self.config.train_cameras_sampling_seed)
            indices = list(range(num_train_cameras))
            self.random_generator.shuffle(indices)
            return indices
        elif self.config.train_cameras_sampling_strategy == "fps":
            if not hasattr(self, "train_unsampled_epoch_count"):
                np.random.seed(self.config.train_cameras_sampling_seed)  # fix random seed of fpsample
                self.train_unsampled_epoch_count = np.zeros(num_train_cameras)
            camera_origins = self.train_dataset.cameras.camera_to_worlds[..., 3].numpy()
            # We concatenate camera origins with weighted train_unsampled_epoch_count because we want to
            # increase the chance to sample camera that hasn't been sampled in consecutive epochs previously.
            # We assume the camera origins are also rescaled, so the weight 0.1 is relative to the scale of scene
            data = np.concatenate(
                (camera_origins, 0.1 * np.expand_dims(self.train_unsampled_epoch_count, axis=-1)), axis=-1
            )
            n = self.config.fps_reset_every
            if num_train_cameras < n:
                CONSOLE.log(
                    f"num_train_cameras={num_train_cameras} is smaller than fps_reset_ever={n}, the behavior of "
                    "camera sampler will be very similar to sampling random without replacement (default setting)."
                )
                n = num_train_cameras
            kdline_fps_samples_idx = fpsample.bucket_fps_kdline_sampling(data, n, h=3)

            self.train_unsampled_epoch_count += 1
            self.train_unsampled_epoch_count[kdline_fps_samples_idx] = 0
            return kdline_fps_samples_idx.tolist()
        else:
            raise ValueError(f"Unknown train camera sampling strategy: {self.config.train_cameras_sampling_strategy}")

    @cached_property
    def cached_train(self) -> List[Dict[str, torch.Tensor]]:
        """Get the training images. Will load and undistort the images the
        first time this (cached) property is accessed."""
        if self.config.cache_images == "lazy":
            return []
        return self._load_images("train", cache_images_device=self.config.cache_images)

    @cached_property
    def cached_eval(self) -> List[Dict[str, torch.Tensor]]:
        """Get the eval images. Will load and undistort the images the
        first time this (cached) property is accessed."""
        if self.config.cache_images == "lazy":
            return []
        return self._load_images("eval", cache_images_device=self.config.cache_images)

    def _load_images(
        self, split: Literal["train", "eval"], cache_images_device: Literal["cpu", "gpu"]
    ) -> List[Dict[str, torch.Tensor]]:
        undistorted_images: List[Dict[str, torch.Tensor]] = []

        # Which dataset?
        if split == "train":
            dataset = self.train_dataset
        elif split == "eval":
            dataset = self.eval_dataset
        else:
            assert_never(split)

        depth_filenames = self.train_depth_filenames if split == "train" else self.eval_depth_filenames
        confidence_filenames = self.train_confidence_filenames if split == "train" else self.eval_confidence_filenames
        depth_unit_scale = self.train_depth_unit_scale if split == "train" else self.eval_depth_unit_scale
        depth_scale = self.train_depth_scale if split == "train" else self.eval_depth_scale

        def resolve_depth_target_size(
            source_h: int, source_w: int, image_h: int, image_w: int
        ) -> Tuple[int, int]:
            mode = self.config.depth_resize_mode
            if mode == "image":
                return image_h, image_w
            if mode == "native":
                return source_h, source_w
            if mode == "max_edge":
                max_edge = max(1, int(self.config.depth_max_edge))
                max_source = max(source_h, source_w)
                if max_source <= max_edge:
                    return source_h, source_w
                scale = max_edge / float(max_source)
                target_h = max(1, int(round(source_h * scale)))
                target_w = max(1, int(round(source_w * scale)))
                return target_h, target_w
            assert_never(mode)

        def undistort_idx(idx: int) -> Dict[str, torch.Tensor]:
            cache = self._load_and_process_image(dataset, idx)
            self._attach_depth_confidence(
                idx=idx,
                cache=cache,
                depth_filenames=depth_filenames,
                confidence_filenames=confidence_filenames,
                depth_unit_scale=depth_unit_scale,
                depth_scale=depth_scale,
                resolve_depth_target_size=resolve_depth_target_size,
            )
            return cache

        CONSOLE.log(f"Caching / undistorting {split} images")
        max_workers = self.config.max_thread_workers
        if max_workers is None:
            max_workers = os.cpu_count() or 4
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            undistorted_images = list(
                track(
                    executor.map(
                        undistort_idx,
                        range(len(dataset)),
                    ),
                    description=f"Caching / undistorting {split} images",
                    transient=True,
                    total=len(dataset),
                )
            )

        # Move to device.
        if cache_images_device == "gpu":
            for cache in undistorted_images:
                self._prepare_cache_for_device(cache, cache_images_device)
            self.train_cameras = self.train_dataset.cameras.to(self.device)
        elif cache_images_device == "cpu":
            for cache in undistorted_images:
                self._prepare_cache_for_device(cache, cache_images_device)
            self.train_cameras = self.train_dataset.cameras
        else:
            assert_never(cache_images_device)

        return undistorted_images

    def create_train_dataset(self) -> TDataset:
        """Sets up the data loaders for training"""
        return self.dataset_type(
            dataparser_outputs=self.train_dataparser_outputs,
            scale_factor=self.config.camera_res_scale_factor,
        )

    def create_eval_dataset(self) -> TDataset:
        """Sets up the data loaders for evaluation"""
        return self.dataset_type(
            dataparser_outputs=self.dataparser.get_dataparser_outputs(split=self.test_split),
            scale_factor=self.config.camera_res_scale_factor,
        )

    @cached_property
    def dataset_type(self) -> Type[TDataset]:
        """Returns the dataset type passed as the generic argument"""
        default: Type[TDataset] = cast(TDataset, TDataset.__default__)  # type: ignore
        orig_class: Type[FullImageDatamanager] = get_orig_class(self, default=None)  # type: ignore
        if type(self) is FullImageDatamanager and orig_class is None:
            return default
        if orig_class is not None and get_origin(orig_class) is FullImageDatamanager:
            return get_args(orig_class)[0]

        # For inherited classes, we need to find the correct type to instantiate
        for base in getattr(self, "__orig_bases__", []):
            if get_origin(base) is FullImageDatamanager:
                for value in get_args(base):
                    if isinstance(value, ForwardRef):
                        if value.__forward_evaluated__:
                            value = value.__forward_value__
                        elif value.__forward_module__ is None:
                            value.__forward_module__ = type(self).__module__
                            value = getattr(value, "_evaluate")(None, None, set())
                    assert isinstance(value, type)
                    if issubclass(value, InputDataset):
                        return cast(Type[TDataset], value)
        return default

    def get_datapath(self) -> Path:
        return self.config.dataparser.data

    def setup_train(self):
        """Sets up the data loaders for training"""

    def setup_eval(self):
        """Sets up the data loader for evaluation"""

    @property
    def fixed_indices_eval_dataloader(self) -> List[Tuple[Cameras, Dict]]:
        """
        Pretends to be the dataloader for evaluation, it returns a list of (camera, data) tuples
        """
        image_indices = [i for i in range(len(self.eval_dataset))]
        if self.config.cache_images == "lazy":
            data = [self._get_cached_data("eval", i).copy() for i in image_indices]
        else:
            data = [d.copy() for d in self.cached_eval]
        _cameras = deepcopy(self.eval_dataset.cameras).to(self.device)
        cameras = []
        for i in image_indices:
            data[i]["image"] = data[i]["image"].to(self.device)
            cameras.append(_cameras[i : i + 1])
        assert len(self.eval_dataset.cameras.shape) == 1, "Assumes single batch dimension"
        return list(zip(cameras, data))

    def get_param_groups(self) -> Dict[str, List[Parameter]]:
        """Get the param groups for the data manager.
        Returns:
            A list of dictionaries containing the data manager's param groups.
        """
        return {}

    def get_train_rays_per_batch(self):
        """Returns resolution of the image returned from datamanager."""
        if self.config.cache_images == "lazy":
            cache = self._get_cached_data("train", 0)
            h = cache["image"].shape[0]
            w = cache["image"].shape[1]
            return h * w
        if len(self.cached_train) != 0:
            h = self.cached_train[0]["image"].shape[0]
            w = self.cached_train[0]["image"].shape[1]
            return h * w
        return 800 * 800

    def next_train(self, step: int) -> Tuple[Cameras, Dict]:
        """Returns the next training batch

        Returns a Camera instead of raybundle"""
        if self._prefetch_stream is not None:
            self._prefetch_next_train()

        image_idx = self.train_unseen_cameras.pop(0)
        # Make sure to re-populate the unseen cameras list if we have exhausted it
        if len(self.train_unseen_cameras) == 0:
            self.train_unseen_cameras = self.sample_train_cameras()

        if self._prefetch_stream is not None and self._prefetch_train_idx == image_idx:
            torch.cuda.current_stream().wait_stream(self._prefetch_stream)
            assert self._prefetch_train is not None
            camera, data = self._prefetch_train
            self._prefetch_train = None
            self._prefetch_train_idx = None
        else:
            data = self._get_cached_data("train", image_idx)
            # We're going to copy to make sure we don't mutate the cached dictionary.
            # This can cause a memory leak: https://github.com/nerfstudio-project/nerfstudio/issues/3335
            data = data.copy()
            self._move_batch_to_device(data)

            assert len(self.train_cameras.shape) == 1, "Assumes single batch dimension"
            camera = self.train_cameras[image_idx : image_idx + 1].to(self.device)
            if camera.metadata is None:
                camera.metadata = {}
            camera.metadata["cam_idx"] = image_idx

        if self._prefetch_stream is not None:
            self._prefetch_next_train()

        return camera, data

    def next_eval(self, step: int) -> Tuple[Cameras, Dict]:
        """Returns the next evaluation batch

        Returns a Camera instead of raybundle"""
        return self.next_eval_image(step=step)

    def next_eval_image(self, step: int) -> Tuple[Cameras, Dict]:
        """Returns the next evaluation batch

        Returns a Camera instead of raybundle

        TODO: Make sure this logic is consistent with the vanilladatamanager"""
        image_idx = self.eval_unseen_cameras.pop(random.randint(0, len(self.eval_unseen_cameras) - 1))
        # Make sure to re-populate the unseen cameras list if we have exhausted it
        if len(self.eval_unseen_cameras) == 0:
            self.eval_unseen_cameras = [i for i in range(len(self.eval_dataset))]
        data = self._get_cached_data("eval", image_idx)
        data = data.copy()
        self._move_batch_to_device(data)
        assert len(self.eval_dataset.cameras.shape) == 1, "Assumes single batch dimension"
        camera = self.eval_dataset.cameras[image_idx : image_idx + 1].to(self.device)
        return camera, data

    def _get_cached_data(self, split: Literal["train", "eval"], idx: int) -> Dict[str, torch.Tensor]:
        if self.config.cache_images != "lazy":
            return self.cached_train[idx] if split == "train" else self.cached_eval[idx]

        cache = self._lazy_train_cache if split == "train" else self._lazy_eval_cache
        if idx in cache:
            return cache[idx]

        dataset = self.train_dataset if split == "train" else self.eval_dataset
        data = self._load_and_process_image(dataset, idx)

        depth_filenames = self.train_depth_filenames if split == "train" else self.eval_depth_filenames
        confidence_filenames = self.train_confidence_filenames if split == "train" else self.eval_confidence_filenames
        depth_unit_scale = self.train_depth_unit_scale if split == "train" else self.eval_depth_unit_scale
        depth_scale = self.train_depth_scale if split == "train" else self.eval_depth_scale

        def resolve_depth_target_size(
            source_h: int, source_w: int, image_h: int, image_w: int
        ) -> Tuple[int, int]:
            mode = self.config.depth_resize_mode
            if mode == "image":
                return image_h, image_w
            if mode == "native":
                return source_h, source_w
            if mode == "max_edge":
                max_edge = max(1, int(self.config.depth_max_edge))
                max_source = max(source_h, source_w)
                if max_source <= max_edge:
                    return source_h, source_w
                scale = max_edge / float(max_source)
                target_h = max(1, int(round(source_h * scale)))
                target_w = max(1, int(round(source_w * scale)))
                return target_h, target_w
            assert_never(mode)

        self._attach_depth_confidence(
            idx=idx,
            cache=data,
            depth_filenames=depth_filenames,
            confidence_filenames=confidence_filenames,
            depth_unit_scale=depth_unit_scale,
            depth_scale=depth_scale,
            resolve_depth_target_size=resolve_depth_target_size,
        )

        self._prepare_cache_for_device(data, "cpu")
        cache[idx] = data
        return data

    def _move_batch_to_device(self, batch: Dict[str, torch.Tensor]) -> None:
        for key in ("image", "mask", "depth", "confidence"):
            if key in batch and isinstance(batch[key], torch.Tensor):
                batch[key] = batch[key].to(self.device, non_blocking=self.config.non_blocking_transfers)

    def _prefetch_next_train(self) -> None:
        if self._prefetch_stream is None:
            return
        if len(self.train_unseen_cameras) == 0:
            self.train_unseen_cameras = self.sample_train_cameras()
        next_idx = self.train_unseen_cameras[0]
        if self._prefetch_train_idx == next_idx:
            return

        data = self._get_cached_data("train", next_idx).copy()
        assert len(self.train_cameras.shape) == 1, "Assumes single batch dimension"
        camera = self.train_cameras[next_idx : next_idx + 1]

        with torch.cuda.stream(self._prefetch_stream):
            self._move_batch_to_device(data)
            camera = camera.to(self.device)

        if camera.metadata is None:
            camera.metadata = {}
        camera.metadata["cam_idx"] = next_idx
        self._prefetch_train = (camera, data)
        self._prefetch_train_idx = next_idx

    def _load_and_process_image(self, dataset: InputDataset, idx: int) -> Dict[str, torch.Tensor]:
        data = dataset.get_data(idx, image_type=self.config.cache_images_type)
        camera = dataset.cameras[idx].reshape(())
        assert data["image"].shape[1] == camera.width.item() and data["image"].shape[0] == camera.height.item(), (
            f'The size of image ({data["image"].shape[1]}, {data["image"].shape[0]}) loaded '
            f'does not match the camera parameters ({camera.width.item(), camera.height.item()})'
        )
        if camera.distortion_params is None or torch.all(camera.distortion_params == 0):
            return data
        K = camera.get_intrinsics_matrices().numpy()
        distortion_params = camera.distortion_params.numpy()
        image = data["image"].numpy()

        K, image, mask = _undistort_image(camera, distortion_params, data, image, K)
        data["image"] = torch.from_numpy(image)
        if mask is not None:
            data["mask"] = mask

        dataset.cameras.fx[idx] = float(K[0, 0])
        dataset.cameras.fy[idx] = float(K[1, 1])
        dataset.cameras.cx[idx] = float(K[0, 2])
        dataset.cameras.cy[idx] = float(K[1, 2])
        dataset.cameras.width[idx] = image.shape[1]
        dataset.cameras.height[idx] = image.shape[0]
        return data

    def _attach_depth_confidence(
        self,
        idx: int,
        cache: Dict[str, torch.Tensor],
        depth_filenames: Optional[List[Path]],
        confidence_filenames: Optional[List[Path]],
        depth_unit_scale: float,
        depth_scale: float,
        resolve_depth_target_size,
    ) -> None:
        if depth_filenames and idx < len(depth_filenames):
            depth_path = depth_filenames[idx]
            if depth_path and Path(depth_path).exists():
                depth_raw = cv2.imread(str(depth_path), cv2.IMREAD_UNCHANGED)
                if depth_raw is not None:
                    depth = depth_raw.astype(np.float32) * float(depth_unit_scale)
                    image_h, image_w = cache["image"].shape[0], cache["image"].shape[1]
                    target_h, target_w = resolve_depth_target_size(depth.shape[0], depth.shape[1], image_h, image_w)
                    if depth.shape[0] != target_h or depth.shape[1] != target_w:
                        depth = cv2.resize(depth, (target_w, target_h), interpolation=cv2.INTER_NEAREST)
                    if self.config.depth_dtype == "float16":
                        depth = depth.astype(np.float16)
                    cache["depth"] = torch.from_numpy(depth)[..., None]
                    cache["depth_scale"] = float(depth_scale)

        if confidence_filenames and idx < len(confidence_filenames):
            confidence_path = confidence_filenames[idx]
            if confidence_path and Path(confidence_path).exists():
                confidence_raw = cv2.imread(str(confidence_path), cv2.IMREAD_UNCHANGED)
                if confidence_raw is not None:
                    if self.config.confidence_dtype == "uint8":
                        confidence = confidence_raw.astype(np.uint8)
                    elif self.config.confidence_dtype == "float16":
                        confidence = confidence_raw.astype(np.float16)
                    else:
                        confidence = confidence_raw.astype(np.float32)
                    image_h, image_w = cache["image"].shape[0], cache["image"].shape[1]
                    target_h, target_w = resolve_depth_target_size(
                        confidence.shape[0], confidence.shape[1], image_h, image_w
                    )
                    if confidence.shape[0] != target_h or confidence.shape[1] != target_w:
                        confidence = cv2.resize(confidence, (target_w, target_h), interpolation=cv2.INTER_NEAREST)
                    cache["confidence"] = torch.from_numpy(confidence)[..., None]

    def _prepare_cache_for_device(
        self, cache: Dict[str, torch.Tensor], cache_images_device: Literal["cpu", "gpu"]
    ) -> None:
        if cache_images_device == "gpu":
            cache["image"] = cache["image"].to(self.device, non_blocking=self.config.non_blocking_transfers)
            if "mask" in cache:
                cache["mask"] = cache["mask"].to(self.device, non_blocking=self.config.non_blocking_transfers)
            if "depth" in cache:
                cache["depth"] = cache["depth"].to(self.device, non_blocking=self.config.non_blocking_transfers)
            if "confidence" in cache:
                cache["confidence"] = cache["confidence"].to(self.device, non_blocking=self.config.non_blocking_transfers)
            return
        if cache_images_device == "cpu":
            cache["image"] = cache["image"].pin_memory()
            if "mask" in cache:
                cache["mask"] = cache["mask"].pin_memory()
            if "depth" in cache:
                cache["depth"] = cache["depth"].pin_memory()
            if "confidence" in cache:
                cache["confidence"] = cache["confidence"].pin_memory()
            return
        assert_never(cache_images_device)


def _undistort_image(
    camera: Cameras, distortion_params: np.ndarray, data: dict, image: np.ndarray, K: np.ndarray
) -> Tuple[np.ndarray, np.ndarray, Optional[torch.Tensor]]:
    mask = None
    if camera.camera_type.item() == CameraType.PERSPECTIVE.value:
        assert distortion_params[3] == 0, (
            "We doesn't support the 4th Brown parameter for image undistortion, "
            "Only k1, k2, k3, p1, p2 can be non-zero."
        )
        # because OpenCV expects the order of distortion parameters to be (k1, k2, p1, p2, k3), we need to reorder them
        # see https://docs.opencv.org/4.x/dc/dbb/tutorial_py_calibration.html
        distortion_params = np.array(
            [
                distortion_params[0],
                distortion_params[1],
                distortion_params[4],
                distortion_params[5],
                distortion_params[2],
                distortion_params[3],
                0,
                0,
            ]
        )
        # because OpenCV expects the pixel coord to be top-left, we need to shift the principal point by 0.5
        # see https://github.com/nerfstudio-project/nerfstudio/issues/3048
        K[0, 2] = K[0, 2] - 0.5
        K[1, 2] = K[1, 2] - 0.5
        if np.any(distortion_params):
            newK, roi = cv2.getOptimalNewCameraMatrix(K, distortion_params, (image.shape[1], image.shape[0]), 0)
            image = cv2.undistort(image, K, distortion_params, None, newK)  # type: ignore
        else:
            newK = K
            roi = 0, 0, image.shape[1], image.shape[0]
        # crop the image and update the intrinsics accordingly
        x, y, w, h = roi
        image = image[y : y + h, x : x + w]
        # update the principal point based on our cropped region of interest (ROI)
        newK[0, 2] -= x
        newK[1, 2] -= y
        if "depth_image" in data:
            data["depth_image"] = data["depth_image"][y : y + h, x : x + w]
        if "mask" in data:
            mask = data["mask"].numpy()
            mask = mask.astype(np.uint8) * 255
            if np.any(distortion_params):
                mask = cv2.undistort(mask, K, distortion_params, None, newK)  # type: ignore
            mask = mask[y : y + h, x : x + w]
            mask = torch.from_numpy(mask).bool()
            if len(mask.shape) == 2:
                mask = mask[:, :, None]
        newK[0, 2] = newK[0, 2] + 0.5
        newK[1, 2] = newK[1, 2] + 0.5
        K = newK

    elif camera.camera_type.item() == CameraType.FISHEYE.value:
        K[0, 2] = K[0, 2] - 0.5
        K[1, 2] = K[1, 2] - 0.5
        distortion_params = np.array(
            [distortion_params[0], distortion_params[1], distortion_params[2], distortion_params[3]]
        )
        newK = cv2.fisheye.estimateNewCameraMatrixForUndistortRectify(
            K, distortion_params, (image.shape[1], image.shape[0]), np.eye(3), balance=0
        )
        map1, map2 = cv2.fisheye.initUndistortRectifyMap(
            K, distortion_params, np.eye(3), newK, (image.shape[1], image.shape[0]), cv2.CV_32FC1
        )
        # and then remap:
        image = cv2.remap(image, map1, map2, interpolation=cv2.INTER_LINEAR)
        if "mask" in data:
            mask = data["mask"].numpy()
            mask = mask.astype(np.uint8) * 255
            mask = cv2.fisheye.undistortImage(mask, K, distortion_params, None, newK)
            mask = torch.from_numpy(mask).bool()
            if len(mask.shape) == 2:
                mask = mask[:, :, None]
        newK[0, 2] = newK[0, 2] + 0.5
        newK[1, 2] = newK[1, 2] + 0.5
        K = newK
    elif camera.camera_type.item() == CameraType.FISHEYE624.value:
        fisheye624_params = torch.cat(
            [camera.fx, camera.fy, camera.cx, camera.cy, torch.from_numpy(distortion_params)], dim=0
        )
        assert fisheye624_params.shape == (16,)
        assert (
            "mask" not in data
            and camera.metadata is not None
            and "fisheye_crop_radius" in camera.metadata
            and isinstance(camera.metadata["fisheye_crop_radius"], float)
        )
        fisheye_crop_radius = camera.metadata["fisheye_crop_radius"]

        # Approximate the FOV of the unmasked region of the camera.
        upper, lower, left, right = fisheye624_unproject_helper(
            torch.tensor(
                [
                    [camera.cx, camera.cy - fisheye_crop_radius],
                    [camera.cx, camera.cy + fisheye_crop_radius],
                    [camera.cx - fisheye_crop_radius, camera.cy],
                    [camera.cx + fisheye_crop_radius, camera.cy],
                ],
                dtype=torch.float32,
            )[None],
            params=fisheye624_params[None],
        ).squeeze(dim=0)
        fov_radians = torch.max(
            torch.acos(torch.sum(upper * lower / torch.linalg.norm(upper) / torch.linalg.norm(lower))),
            torch.acos(torch.sum(left * right / torch.linalg.norm(left) / torch.linalg.norm(right))),
        )

        # Heuristics to determine parameters of an undistorted image.
        undist_h = int(fisheye_crop_radius * 2)
        undist_w = int(fisheye_crop_radius * 2)
        undistort_focal = undist_h / (2 * torch.tan(fov_radians / 2.0))
        undist_K = torch.eye(3)
        undist_K[0, 0] = undistort_focal  # fx
        undist_K[1, 1] = undistort_focal  # fy
        undist_K[0, 2] = (undist_w - 1) / 2.0  # cx; for a 1x1 image, center should be at (0, 0).
        undist_K[1, 2] = (undist_h - 1) / 2.0  # cy

        # Undistorted 2D coordinates -> rays -> reproject to distorted UV coordinates.
        undist_uv_homog = torch.stack(
            [
                *torch.meshgrid(
                    torch.arange(undist_w, dtype=torch.float32),
                    torch.arange(undist_h, dtype=torch.float32),
                ),
                torch.ones((undist_w, undist_h), dtype=torch.float32),
            ],
            dim=-1,
        )
        assert undist_uv_homog.shape == (undist_w, undist_h, 3)
        dist_uv = (
            fisheye624_project(
                xyz=(
                    torch.einsum(
                        "ij,bj->bi",
                        torch.linalg.inv(undist_K),
                        undist_uv_homog.reshape((undist_w * undist_h, 3)),
                    )[None]
                ),
                params=fisheye624_params[None, :],
            )
            .reshape((undist_w, undist_h, 2))
            .numpy()
        )
        map1 = dist_uv[..., 1]
        map2 = dist_uv[..., 0]

        # Use correspondence to undistort image.
        image = cv2.remap(image, map1, map2, interpolation=cv2.INTER_LINEAR)

        # Compute undistorted mask as well.
        dist_h = camera.height.item()
        dist_w = camera.width.item()
        mask = np.mgrid[:dist_h, :dist_w]
        mask[0, ...] -= dist_h // 2
        mask[1, ...] -= dist_w // 2
        mask = np.linalg.norm(mask, axis=0) < fisheye_crop_radius
        mask = torch.from_numpy(
            cv2.remap(
                mask.astype(np.uint8) * 255,
                map1,
                map2,
                interpolation=cv2.INTER_LINEAR,
                borderMode=cv2.BORDER_CONSTANT,
                borderValue=0,
            )
            / 255.0
        ).bool()[..., None]
        if len(mask.shape) == 2:
            mask = mask[:, :, None]
        assert mask.shape == (undist_h, undist_w, 1)
        K = undist_K.numpy()
    else:
        raise NotImplementedError("Only perspective and fisheye cameras are supported")

    return K, image, mask
