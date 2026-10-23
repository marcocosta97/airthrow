#!/usr/bin/env python3
"""Convert official DRUNet Color for an isolated same-resolution benchmark.

Architecture: https://github.com/cszn/DPIR (UNetRes, strideconv/convtranspose).
No downloaded Python is executed; checkpoints use torch's weights-only loader.
Models and Python dependencies remain outside the application bundle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import coremltools as ct
import numpy as np
from PIL import Image
import torch
from torch import nn

class ResBlock(nn.Module):
    def __init__(self, channels):
        super().__init__()
        self.res = nn.Sequential(nn.Conv2d(channels, channels, 3, padding=1, bias=False),
                                 nn.ReLU(), nn.Conv2d(channels, channels, 3, padding=1, bias=False))
    def forward(self, x):
        return x + self.res(x)

class DRUNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.m_head = nn.Conv2d(4, 64, 3, padding=1, bias=False)
        for index, (cin, cout) in enumerate([(64,128), (128,256), (256,512)], 1):
            setattr(self, f'm_down{index}', nn.Sequential(*[ResBlock(cin) for _ in range(4)],
                nn.Conv2d(cin, cout, 2, stride=2, bias=False)))
        self.m_body = nn.Sequential(*[ResBlock(512) for _ in range(4)])
        for index, (cin, cout) in zip([3,2,1], [(512,256),(256,128),(128,64)]):
            setattr(self, f'm_up{index}', nn.Sequential(nn.ConvTranspose2d(cin, cout, 2, stride=2, bias=False),
                *[ResBlock(cout) for _ in range(4)]))
        self.m_tail = nn.Conv2d(64, 3, 3, padding=1, bias=False)
    def forward(self, x):
        x1 = self.m_head(x); x2 = self.m_down1(x1); x3 = self.m_down2(x2); x4 = self.m_down3(x3)
        return self.m_tail(self.m_up1(self.m_up2(self.m_up3(self.m_body(x4) + x4) + x3) + x2) + x1)

class DenoiseImage(nn.Module):
    def __init__(self, model, sigma, width, height):
        super().__init__(); self.model = model; self.sigma = sigma / 255
        self.width = width; self.height = height
    def forward(self, x):
        x = torch.nn.functional.pad(x, (0, (-self.width) % 8, 0, (-self.height) % 8), mode='replicate')
        noise = torch.ones_like(x[:, :1]) * self.sigma
        return self.model(torch.cat([x, noise], dim=1))[:, :, :self.height, :self.width].clamp(0, 1) * 255

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--width', type=int, default=960)
    parser.add_argument('--height', type=int, default=540)
    parser.add_argument('--sigma', type=float, default=10)
    args = parser.parse_args()
    if args.width < 8 or args.height < 8 or not 0 < args.sigma <= 50: parser.error('Invalid dimensions or sigma')
    torch.set_num_threads(4); torch.manual_seed(42)
    weights = args.directory / 'drunet_color.pth'
    model = DRUNet().eval()
    model.load_state_dict(torch.load(weights, map_location='cpu', weights_only=True), strict=True)
    wrapper = DenoiseImage(model, args.sigma, args.width, args.height).eval()
    shape = (1,3,args.height,args.width)
    traced = torch.jit.trace(wrapper, torch.zeros(shape), check_trace=False)
    path = args.directory / f'DRUNet-color-{args.width}x{args.height}-sigma{args.sigma:g}.mlpackage'
    if path.exists(): raise RuntimeError('Refusing to overwrite model package')
    converted = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_ONLY,
        inputs=[ct.ImageType(name='image', shape=shape, scale=1/255, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name='output', color_layout=ct.colorlayout.RGB)])
    converted.save(str(path))
    rng = np.random.default_rng(42)
    yy, xx = np.mgrid[:args.height, :args.width]
    field = np.stack([40+150*xx/args.width, 60+130*yy/args.height, np.full_like(xx,128)], axis=-1)
    rgb = np.clip(field + rng.normal(0,args.sigma,field.shape),0,255).astype(np.uint8)
    with torch.no_grad(): reference = wrapper(torch.from_numpy(rgb.transpose(2,0,1).copy()).float()[None]/255)[0].permute(1,2,0).numpy()
    predicted = np.asarray(converted.predict({'image':Image.fromarray(rgb)})['output'].convert('RGB'))
    error = np.abs(reference - predicted.astype(np.float32))
    record = dict(model='DRUNet Color', sigma=args.sigma, inputWidth=args.width, inputHeight=args.height,
        scale=1, padding='replicate to multiple of eight, crop to original dimensions', package=path.name,
        weightsSha256=hashlib.sha256(weights.read_bytes()).hexdigest(),
        source='https://github.com/cszn/KAIR/releases/download/v1.0/drunet_color.pth',
        architecture='https://github.com/cszn/DPIR/blob/master/models/network_unet.py',
        parameters=sum(p.numel() for p in model.parameters()),
        packageBytes=sum(p.stat().st_size for p in path.rglob('*') if p.is_file()),
        conversionMeanAbsoluteRGBError=float(error.mean()), conversionP99RGBError=float(np.percentile(error,99)))
    print(json.dumps(record),flush=True)
    (path.with_suffix('.json')).write_text(json.dumps(record,indent=2)+'\n')
    if error.mean() > 1 or np.percentile(error,99) > 3: raise RuntimeError('Core ML conversion differs from PyTorch')

if __name__ == '__main__': main()
