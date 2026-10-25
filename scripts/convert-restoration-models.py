#!/usr/bin/env python3
"""Convert official QuickSRNet checkpoints for the isolated native benchmark.

Install torch 2.2.2, numpy 1.26.4 and coremltools 8.3 in a local virtualenv.
Checkpoint URLs and hashes are retained in the generated manifest. No weights
or Python runtime are bundled in AirThrow.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import pickle
import types

import coremltools as ct
import numpy as np
import torch
from torch import nn


class IgnoredOptimizer:
    def __setstate__(self, state):
        pass


class CheckpointUnpickler(pickle.Unpickler):
    """Only allow tensor reconstruction and inert training-state containers."""
    def find_class(self, module, name):
        allowed = {
            ("collections", "OrderedDict"): collections.OrderedDict,
            ("collections", "defaultdict"): collections.defaultdict,
            ("__builtin__", "dict"): dict,
            ("torch", "FloatStorage"): torch.FloatStorage,
            ("torch._utils", "_rebuild_parameter"): torch._utils._rebuild_parameter,
            ("torch._utils", "_rebuild_tensor_v2"): torch._utils._rebuild_tensor_v2,
            ("torch.optim.adam", "Adam"): IgnoredOptimizer,
        }
        if (module, name) not in allowed:
            raise pickle.UnpicklingError(f"Unexpected checkpoint class: {module}.{name}")
        return allowed[module, name]


class QuickSR(nn.Module):
    """Official Small/Medium inference architecture: clipped CNN + PixelShuffle."""
    def __init__(self, intermediate):
        super().__init__()
        layers = [nn.Conv2d(3, 32, 3, padding=1), nn.Hardtanh(0.0, 1.0)]
        for _ in range(intermediate):
            layers += [nn.Conv2d(32, 32, 3, padding=1), nn.Hardtanh(0.0, 1.0)]
        self.cnn = nn.Sequential(*layers)
        self.conv_last = nn.Conv2d(32, 12, 3, padding=1)

    def forward(self, x):
        return torch.nn.functional.pixel_shuffle(self.conv_last(self.cnn(x)).clamp(0.0, 1.0), 2)


class ImageOutput(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        return self.model(x) * 255.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--variant", choices=["both", "small", "medium"], default="both")
    parser.add_argument("--include-4k", action="store_true", help="Also permit 1920x1080 input for the 4K feasibility run")
    args = parser.parse_args()
    report = []
    safe_pickle = types.SimpleNamespace(__name__="checkpoint_pickle", Unpickler=CheckpointUnpickler,
                                        load=pickle.load, loads=pickle.loads)
    for name, layers in [("small", 2), ("medium", 5)]:
        if args.variant != "both" and name != args.variant:
            continue
        checkpoint = args.directory / f"{name}-2x.pth"
        data = torch.load(checkpoint, map_location="cpu", pickle_module=safe_pickle, weights_only=False)
        model = QuickSR(layers).eval()
        model.load_state_dict(data["state_dict"], strict=True)
        image_model = ImageOutput(model).eval()
        shape = (1, 3, 540, 960)
        traced = torch.jit.trace(image_model, torch.zeros(shape))
        permitted = [shape, (1, 3, 240, 136), (1, 3, 360, 640)]
        if args.include_4k:
            permitted.append((1, 3, 1080, 1920))
        shapes = ct.EnumeratedShapes(shapes=permitted, default=shape)
        path = args.directory / f"QuickSRNet-{name}-2x.mlpackage"
        converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
            compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_ONLY,
            inputs=[ct.ImageType(name="image", shape=shapes, scale=1/255, color_layout=ct.colorlayout.RGB)],
            outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)])
        if not path.exists():
            converted.save(str(path))
        else:
            converted = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
        # Validate conversion against PyTorch on a deterministic RGB image.
        from PIL import Image
        rng = np.random.default_rng(42)
        rgb = rng.integers(0, 256, (240, 136, 3), dtype=np.uint8)
        with torch.no_grad():
            reference = image_model(torch.from_numpy(rgb.transpose(2, 0, 1).copy()).float()[None] / 255)
        predicted = np.asarray(converted.predict({"image": Image.fromarray(rgb)})["output"].convert("RGB"))
        reference = reference[0].permute(1, 2, 0).numpy()
        difference = np.abs(reference-predicted.astype(np.float32))
        print(json.dumps(dict(validation=name, mean=float(difference.mean()), p99=float(np.percentile(difference, 99)))), flush=True)
        # RGB output has one-code rounding; accumulated FP16 error must remain
        # below one code on average and three codes (1.2%) for 99% of values.
        if difference.mean() > 1 or np.percentile(difference, 99) > 3:
            raise RuntimeError("Core ML conversion does not match PyTorch")
        record = dict(model=name, package=path.name, checkpointSha256=hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
            source=f"https://github.com/quic/aimet-model-zoo/releases/download/phase_2_january_artifacts/quicksrnet_{name}_2x_checkpoint_float32.pth.tar",
            parameters=sum(p.numel() for p in model.parameters()), inputShapes=permitted,
            conversionMeanAbsoluteRGBError=float(difference.mean()), conversionP99RGBError=float(np.percentile(difference, 99)),
            packageBytes=sum(p.stat().st_size for p in path.rglob('*') if p.is_file()))
        report.append(record)
        print(json.dumps(record), flush=True)
        (args.directory / "conversion.json").write_text(json.dumps(report, indent=2)+"\n")


if __name__ == "__main__":
    main()
