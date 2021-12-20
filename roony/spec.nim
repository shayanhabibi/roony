const
  rqOrder* = 16                   # Dictates the size of the queues
  lfCacheShift = 7u
  lfringMin* = lfCacheShift - 3u
  
template lfMerge*(x,y: typed): untyped =
  x or y
template lfPow*(x: SomeInteger = rqOrder): uint =
  1u shl x
template lfCmp*(x: typed, op: untyped, y: typed): untyped =
  op(cast[int]((x - y)), 0)

template lfThreshold*(half, n: typed): untyped =
  cast[int]((half + n - 1))

proc lfRawMap*(idx, order, n: uint): uint {.inline.} =
  result =
    ((idx and (n - 1)) shr (order - lfringMin)) or
    ((idx shl lfringMin) and (n - 1))

proc lfMap*(idx: uint, n: uint, order: uint = rqOrder): uint {.inline.} =
  result = lfRawMap(idx, order + 1, n)