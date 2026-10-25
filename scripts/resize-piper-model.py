#!/usr/bin/env python3
"""Prepare a fixed full-frame experiment from PiperSR's fully convolutional release.

Changes image/activation dimensions only; keeps every operation and weight.
The resulting model must be checked against the released model before use.
"""
import argparse
import json
from pathlib import Path
import coremltools as ct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--width', type=int, required=True)
parser.add_argument('--height', type=int, required=True)
args = parser.parse_args()
if args.output.exists(): parser.error('Output already exists')
spec = ct.models.MLModel(str(args.source), skip_model_load=True).get_spec()
allowed = {'const','mul','cast','conv','silu','add','pixel_shuffle','clip'}
changes = 0

def resize(value):
    global changes
    dims = value.type.tensorType.dimensions
    sizes = [d.constant.size for d in dims]
    if len(sizes)==4 and sizes[0]==1 and sizes[-2:]==[128,128]:
        dims[-2].constant.size = args.height; dims[-1].constant.size = args.width; changes += 1
    elif sizes == [1,3,256,256]:
        dims[-2].constant.size = args.height*2; dims[-1].constant.size = args.width*2; changes += 1

for function in spec.mlProgram.functions.values():
    for value in function.inputs: resize(value)
    for block in function.block_specializations.values():
        for op in block.operations:
            if op.type not in allowed: raise RuntimeError(f'Unreviewed operation: {op.type}')
            for value in op.outputs:
                if op.type != 'const': resize(value)
for direction, scale in [(spec.description.input,1),(spec.description.output,2)]:
    for feature in direction:
        image = feature.type.imageType
        if not image.width or not image.height: raise RuntimeError('Expected an image feature')
        image.width = args.width*scale; image.height = args.height*scale
        image.ClearField('imageSizeRange'); image.ClearField('enumeratedSizes')
model = ct.models.MLModel(spec, weights_dir=str(args.source/'Data/com.apple.CoreML/weights'), skip_model_load=True)
model.save(str(args.output))
print(json.dumps(dict(source=str(args.source), output=str(args.output), dimensionChanges=changes,
    weightsUnchanged=True, operationsUnchanged=True)))
