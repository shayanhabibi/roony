import wtbanland/atomics

import roony/spec

type
  RingQueue*[N: static uint] = object
    ## Naive Ring Queue
    head* {.align(128).}: Atomic[uint]
    threshold* {.align(128).}: Atomic[int]
    tail* {.align(128).}: Atomic[uint]
    arr* {.align(128).}: array[N, Atomic[uint]]

proc newEmptyRingQueue*(): auto =
  ## Creates and initiates a Ring Queue in the empty state
  const sz = lfPow(rqOrder + 1)
  
  result = RingQueue[sz]()

  for i,x in result.arr:
    # Every index in the array is initialised as empty (all bits set)
    result.arr[i].store(cast[uint](-1))
  
  result.threshold.store(-1)  # Init the threshold

proc newFullRingQueue*(): auto =
  ## Creates and initiates a Ring Queue in the full state
  const half: uint = lfPow(rqOrder)
  const n = half * 2
  
  result = RingQueue[n]()

  for i in 0..<half:
    result.arr[lfMap(i.uint, n)].store(lfRawMap(n + i.uint, rqOrder, half))
  for i in half..<n:
    result.arr[lfMap(i.uint, n)].store(cast[uint](-1))
  
  result.threshold.store(lfThreshold(half, n))
  result.tail.store(half)


proc push*[N](rq: var RingQueue[N]; eidx: var uint; nonempty: bool): bool {.inline, discardable.} =
  var tidx, half, n: uint
  var tail, entry, ecycle, tcycle: uint
  
  half = lfPow rqOrder
  n = half * 2
  eidx = eidx xor (n - 1)

  while true:
    tail = rq.tail.fetchAdd(1, moAcqRel)
    tcycle = (tail shl 1) or (2 * n - 1)
    tidx = lfMap(tail, n)
    entry = rq.arr[tidx].load(moAcq).uint
    while true:
      ecycle = entry or (2 * n - 1)
      if (
          lfCmp(ecycle, `<`, tcycle) and (
            (entry == ecycle) or (
              (entry == (ecycle xor n)) and lfCmp(rq.head.load(moAcq), `<=`, tail)
              )
            )
          ):
        if not rq.arr[tidx].compareExchangeWeak(entry, (var ieidx = cast[uint](tcycle xor eidx); ieidx), moAcqRel, moAcq):
          continue
        if not(nonempty) and (rq.threshold.load() != lfThreshold(half, n)):
          rq.threshold.store(lfThreshold(half, n))
        return true
      break

proc catchup*[N](rq: var RingQueue[N]; tail, head: uint) {.inline.} =
  var varhead = head
  var vartail = tail
  while not rq.tail.compareExchangeWeak(vartail, varhead, moAcqRel, moAcq):
    varhead = rq.head.load(moAcq)
    vartail = rq.tail.load(moAcq)
    if lfCmp(vartail, `>=`, varhead):
      break

proc pop*[N](rq: var RingQueue[N]; nonempty: bool): uint =
  var hidx, n: uint
  var head, entry, entryNew, ecycle, hcycle, tail: uint
  var attempt: uint
  
  n = lfPow(rqOrder + 1)

  if not(nonempty) and (rq.threshold.load() < 0):
    return high(uint)

  while true:
    head = rq.head.fetchAdd(1, moAcqRel)
    hcycle = (head shl 1) or (2 * n - 1)
    hidx = lfMap(head, n)
    attempt = 0
    block outer:
      while true:
        block inner:
          entry = rq.arr[hidx].load(moAcq).uint
          template cyc(): untyped =
            ecycle = entry or (2 * n - 1)
            if ecycle == hcycle:
              rq.arr[hidx].fetchOr(n - 1, moAcqRel)
              return (entry and (n - 1))
            
            if (entry or n) != ecycle:
              entryNew = entry and (not n)
              if entry == entryNew:
                break
            else:
              inc attempt
              if attempt <= 10_000:
                break inner
              entryNew = hcycle xor ((not entry) and n)
          block:
            cyc()
            while lfCmp(ecycle, `<`, hcycle) and not rq.arr[hidx].compareExchangeWeak(
              entry, entryNew, moAcqRel, moAcq
            ): cyc()
            break outer
            


    if not nonempty:
      tail = rq.tail.load(moAcq)
      if lfCmp(tail, `<=`, (head + 1)):
        catchup(rq, tail, head + 1)
        rq.threshold.fetchSub(1, moAcqRel)
        return high(uint)
      if rq.threshold.fetchSub(1, moAcqRel) <= 0:
        return high(uint)
