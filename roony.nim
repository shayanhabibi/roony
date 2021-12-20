import wtbanland/atomics

import roony/spec

type
  RingQueue[T; N: static uint] = object
    ## Naive Ring Queue
    head {.align(128).}: Atomic[uint]
    threshold {.align(128).}: Atomic[int]
    tail {.align(128).}: Atomic[uint]
    arr {.align(128).}: array[N, Atomic[uint]]

  RoonyQueue*[T; N: static uint] = ref object
    ## Bounded circular queue which uses indirection to store and access values
    aqo: RingQueue[T, N]
    fqo: RingQueue[T, N]
    val: array[N, T]

proc newEmptyRingQueue[T](): auto =
  ## Creates and initiates a Ring Queue in the empty state
  const sz = lfPow(rqOrder + 1)
  
  result = RingQueue[T, sz]()

  for i,x in result.arr:
    # Every index in the array is initialised as empty (all bits set)
    result.arr[i].store(cast[uint](-1))
  
  result.threshold.store(-1)  # Init the threshold

proc newFullRingQueue[T](): auto =
  ## Creates and initiates a Ring Queue in the full state
  const half: uint = lfPow(rqOrder)
  const n = half * 2
  
  result = RingQueue[T, n]()

  for i in 0..<half:
    result.arr[lfMap(i.uint, n)].store(lfRawMap(n + i.uint, rqOrder, half))
  for i in half..<n:
    result.arr[lfMap(i.uint, n)].store(cast[uint](-1))
  
  result.threshold.store(lfThreshold(half, n))
  result.tail.store(half)

proc push[T; N](rq: var RingQueue[T, N]; eidx: var uint; nonempty: bool): bool {.inline, discardable.} =
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

proc catchup[T; N](rq: var RingQueue[T, N]; tail, head: uint) {.inline.} =
  var varhead = head
  var vartail = tail
  while not rq.tail.compareExchangeWeak(vartail, varhead, moAcqRel, moAcq):
    varhead = rq.head.load(moAcq)
    vartail = rq.tail.load(moAcq)
    if lfCmp(vartail, `>=`, varhead):
      break

proc pop[T; N](rq: var RingQueue[T, N]; nonempty: bool): uint =
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

proc newRoonyQueue*[T](): auto =
  ## Create and initialise a RoonyQueue.
  doAssert sizeof(T) <= 8, "Queue can only handle pointers or objects less than or equal to 8 bytes"
  const sz = 1u shl (rqOrder + 1)

  result =
    RoonyQueue[T, sz](
      aqo: newEmptyRingQueue[T](),
      fqo: newFullRingQueue[T]()
    )

# ----------------------------------------- #
# Accessors to internal ring queues as vars #
proc fq[T; N](sq: RoonyQueue[T, N]): var RingQueue[T, N] = sq.fqo
proc aq[T; N](sq: RoonyQueue[T, N]): var RingQueue[T, N] = sq.aqo
# ----------------------------------------- #

proc push*[T; N](sq: RoonyQueue[T, N]; val: T): bool {.discardable.} =
  ## Push an item (val) onto the queue. False is returned if the queue is full.
  var eidx = sq.fq().pop(true)
  if eidx == high(uint):
    result = false
  else:
    sq.val[eidx] = val
    sq.aq().push(eidx, false)
    result = true

proc pop*[T; N](sq: RoonyQueue[T, N]): T =
  ## Pop an item off the queue. Nil is returned if the queue is empty and must be
  ## handled in user code.
  var eidx = sq.aq().pop(false)
  if eidx != high(uint):
    result = sq.val[eidx]
    when T is ref:
      sq.val[eidx] = nil
    sq.fq().push(eidx, true)