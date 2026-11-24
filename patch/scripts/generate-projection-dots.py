#!/usr/bin/env python3
"""Generate the editable Projection Dots shader with the paper ribbon's CIE model."""
from pathlib import Path
import csv
import math

root = Path(__file__).resolve().parents[1]
rows = [[float(v) for v in row] for row in csv.reader((root / 'User Nodes/Data/CIE_xyz_1931_2deg.csv').open())]
cumulative = [[0.0, 0.0, 0.0]]
for a, b in zip(rows, rows[1:]):
    cumulative.append([cumulative[-1][j] + (a[j + 1] + b[j + 1]) / 2 for j in range(3)])
total = cumulative[-1]
bradford = [[.8951, .2664, -.1614], [-.7502, 1.7135, .0367], [.0389, -.0685, 1.0296]]
inverse = [[.9869929, -.1470543, .1599627], [.4323053, .5183603, .0492912], [-.0085287, .0400428, .9684867]]
xyz_rgb = [[3.2404542, -1.5371385, -.4985314], [-.969266, 1.8760108, .041556], [.0556434, -.2040259, 1.0572252]]
def multiply(m, v):
    return [sum(a * b for a, b in zip(row, v)) for row in m]
source = multiply(bradford, [v / total[1] for v in total])
target = multiply(bradford, [.95047, 1, 1.08883])
def linear_rgb(xyz):
    cone = multiply(bradford, [v / total[1] for v in xyz])
    return multiply(xyz_rgb, multiply(inverse, [v * target[i] / source[i] for i, v in enumerate(cone)]))
def number(v):
    text = f'{v:.9g}'
    if '.' not in text and 'e' not in text:
        text += '.0'
    return text + 'f'
def vec(v):
    return 'float3(' + ','.join(number(x) for x in v) + ')'
def table(name, values):
    return f'constant float3 {name}[{len(values)}] = {{\n' + ',\n'.join(vec(v) for v in values) + '\n};\n'

header = '''// Projection Dots: ordinary RGB pixels on true black, for a real projector.
// CIE 1931 2-degree data, DOI 10.25039/CIE.DS.xvudnb9b, CC BY-SA 4.0.
// Exact same spatial slit/pole integration and Bradford adaptation as
// projection/zon/spectrum.js and pole-stack-paper.blend. No HSV approximation.
// controls follow DotColorsStyle.parameters, four values per slot.
'''
code = header + table('ribbonIntegralRGB', [linear_rgb(v) for v in cumulative])
code += table('ribbonMatchingRGB', [linear_rgb(v[1:]) for v in rows])
code += 'constant float3 ribbonWhite = ' + vec(linear_rgb(total)) + ';\n'
code += r'''
float3 ribbonIntegral(float wavelength) {
    if (wavelength <= 360.0f) return float3(0);
    if (wavelength >= 830.0f) return ribbonIntegralRGB[470];
    float sample = wavelength - 360.0f;
    int i = int(floor(sample));
    float t = sample - float(i);
    return ribbonIntegralRGB[i] + ribbonMatchingRGB[i]*t
        + (ribbonMatchingRGB[i+1]-ribbonMatchingRGB[i])*(t*t*0.5f);
}
float3 ribbonEncode(float3 linear) {
    float3 v = clamp(linear,0.0f,1.0f);
    return select(1.055f*pow(v,float3(1.0f/2.4f))-0.055f,12.92f*v,v<=0.0031308f);
}
float3 dotHSV(float hue,float saturation) {
    float3 p = abs(fract(float3(hue)+float3(0,2.0f/3.0f,1.0f/3.0f))*6.0f-3.0f);
    return mix(float3(1),clamp(p-1.0f,0.0f,1.0f),saturation);
}
float4 dotPattern(float2 cellIndex,float2 grid,float time,constant float4 *c,constant uint *messages) {
    int2 cell = int2(cellIndex);
    int columns = int(grid.x), rows = int(grid.y);
    float2 fraction = float2(columns>1 ? float(cell.x)/float(columns-1) : 0.5f,
                             rows>1 ? float(cell.y)/float(rows-1) : 0.5f);
    int pattern = int(round(c[0].x));
    float phase = c[2].y+time*c[2].z;
    float3 color = float3(1);
    if (pattern<=1) {
        float a=max(0.01f,c[1].x),b=max(0.01f,c[1].y);
        float width = c[2].x<0.5f ? exp(mix(log(a),log(b),fraction.y)) : mix(a,b,fraction.y);
        float position = (fraction.x-0.5f)*c[1].z+c[1].w+sin(phase*6.283185307f)*c[1].z*0.5f;
        float wavelength = 595.0f-position*470.0f;
        float bandwidth = width/27.0f*940.0f;
        float3 transmitted = ribbonIntegral(wavelength+bandwidth*0.5f)-ribbonIntegral(wavelength-bandwidth*0.5f);
        color = ribbonEncode(pattern==0 ? ribbonWhite-transmitted : transmitted);
    } else if (pattern==2 || pattern==3) {
        color = dotHSV((pattern==2 ? fraction.x : fraction.y)+phase+c[0].z,c[0].w);
    } else if (pattern==5) {
        color = dotHSV(c[0].z+phase,c[0].w);
    } else if (pattern==6) {
        color = float3(((cell.x+cell.y)&1)==0 ? 1.0f : 0.0f);
    } else if (pattern==7) {
        if (cell.y==0 && cell.x==0) color=float3(1,0,0);
        else if (cell.y==0 && cell.x==columns-1) color=float3(0,1,0);
        else if (cell.y==rows-1 && cell.x==0) color=float3(0,0,1);
        else if (cell.y==rows-1 && cell.x==columns-1) color=float3(1,1,0);
    }
    return float4(color*clamp(c[0].y,0.0f,1.0f),1);
}
'''
destination = root / 'User Nodes/Dot Colors.metal'
destination.write_text(code)
print(f'Generated {destination.name}: {len(code.encode())} bytes, exact 1 nm CIE integrals')
