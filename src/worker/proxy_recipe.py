# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
"""Versioned proxy recipes; legacy outputs remain explicit and verifiable."""
DEFAULT_DIVISOR=2
PIXEL_FORMAT='yuv422p10le'
BIT_DEPTH=10

def recipe_id(divisor):
    if divisor==2:return 'half-prores-v2'
    if divisor==4:return 'quarter-prores-v1'
    raise ValueError('Only the half and legacy quarter proxy recipes are supported.')

def scale_filter(divisor):
    recipe_id(divisor)
    return f'scale=iw/{divisor}:ih/{divisor}'
