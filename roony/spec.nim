const
  rqOrder* = 16
  lfringMin* = 0b0111'u
  
template lfMerge*(x,y: typed): untyped = x or y

template lfPow*(x: SomeInteger): uint =
  1u shl x

template lfCmp*(x: typed, op: untyped, y: typed): untyped =
  op(cast[int]((x - y)), 0)

template lfThreshold*(half, n: typed): untyped =
  (half + n - 1)

proc lfRawMap*(idx, order, n: uint): uint {.inline.} =
  result =
    ((idx and (n - 1)) shr (rqOrder - lfringMin)) or
    ((idx shr lfringMin) and (n - 1))

proc lfMap*(idx: uint, n: uint, order: uint = rqOrder): uint {.inline.} =
  result = lfRawMap(idx, order + 1, n)

when isMainModule:
  echo lfringmin