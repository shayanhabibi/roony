import wtbanland/atomics

import roony/spec

type
  # RoonyQueueObj[T; N] = object
  RoonyQueue[T; N: static uint] = object
    head: Atomic[uint]
    threshold: Atomic[int]
    tail: Atomic[uint]
    arr: array[N, Atomic[uint]]
  # RoonyQueue[T; N] = ref RoonyQueueObj[T, N]

  SCQueue*[T; N: static uint] = ref object
    aqo: RoonyQueue[T, N]
    fqo: RoonyQueue[T, N]
    val: array[N, T]

const negone: uint = cast[uint](-1)

proc newEmptyRoonyQueue[T](): auto =
  const sz = 1u shl (rqOrder + 1)
  
  result = RoonyQueue[T, sz]()
  result.threshold.store(-1)  # Init the threshold

  for i,x in result.arr:  # init every idx in the array as -1
    result.arr[i].store(negone)
  
proc newFullRoonyQueue[T](): auto =
  const half: uint = lfPow(rqOrder)
  const n = half * 2
  
  result = RoonyQueue[T, n]()

  for i in 0..<half:
    result.arr[lfMap(i.uint, n)].store(lfRawMap(n + i.uint, rqOrder, half))
  for i in half..<n:
    result.arr[lfMap(i.uint, n)].store(negone)
  
  result.threshold.store(lfThreshold(half, n).int)
  result.tail.store(half)



proc push[T; N](rq: var RoonyQueue[T, N]; eidx: var uint; nonempty: bool): bool {.inline, discardable.} =
  var tidx, half, n: uint
  var tail, entry, ecycle, tcycle: uint
  
  half = lfPow rqOrder
  n = half * 2
  eidx = eidx xor (n - 1)

  # var ech: bool
  while true:
    tail = rq.tail.fetchAdd(1, moAcqRel)
    tcycle = (tail shl 1) or (2 * n - 1)
    tidx = lfMap(tail, n)
    entry = rq.arr[tidx].load(moAcq).uint
    while true:
      ecycle = entry or (2 * n - 1)
      # if not ech:
      #   echo "tidx ", tidx
      #   echo entry
      #   echo ecycle
      #   echo tcycle
      #   echo "---"
      #   echo lfCmp(ecycle, `<`, tcycle)
      #   echo (entry == ecycle)
      #   echo (entry == (ecycle xor n))
      #   echo lfCmp(rq.head.load(moAcq), `<=`, tail)
      #   echo "---"
      #   ech = true
      if (
          lfCmp(ecycle, `<`, tcycle) and (
            (entry == ecycle) or (
              (entry == (ecycle xor n)) and lfCmp(rq.head.load(moAcq), `<=`, tail)
              )
            )
          ):
        if not rq.arr[tidx].compareExchangeWeak(entry, (var ieidx = cast[uint](tcycle xor eidx); ieidx), moAcqRel, moAcq):
          continue
        if not(nonempty) and (rq.threshold.load() != lfThreshold(half, n).int):
          rq.threshold.store(lfThreshold(half, n).int)
        return true
      break

proc catchup[T; N](rq: var RoonyQueue[T, N]; tail, head: uint) {.inline.} =
  var varhead = head
  var vartail = tail
  while not rq.tail.compareExchangeWeak(vartail, varhead, moAcqRel, moAcq):
    varhead = rq.head.load(moAcq)
    vartail = rq.tail.load(moAcq)
    if lfCmp(vartail, `>=`, varhead):
      break

proc pop[T; N](rq: var RoonyQueue[T, N]; nonempty: bool): uint =
  var hidx, n: uint
  var head, entry, entryNew, ecycle, hcycle, tail: uint
  var attempt: uint

  result = high(uint)
  
  n = lfPow(rqOrder + 1)

  if not(nonempty) and (rq.threshold.load() < 0):
    return

  while true:
    head = rq.head.fetchAdd(1, moAcqRel)
    hcycle = (head shl 1) or (2 * n - 1)
    hidx = lfMap(head, n)
    attempt = 0
    echo hcycle
    while true:
      entry = rq.arr[hidx].load(moAcq).uint
      ecycle = entry or (2 * n - 1)
      echo ecycle
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
          continue
        entryNew = hcycle xor ((not entry) and n)
      echo "pass"
      if lfCmp(ecycle, `<`, hcycle) and not rq.arr[hidx].compareExchangeWeak(
        entry, entryNew, moAcqRel, moAcq
      ): continue
      else:
        break

    if not nonempty:
      tail = rq.tail.load(moAcq)
      if lfCmp(tail, `<=`, (head + 1)):
        catchup(rq, tail, head + 1)
        rq.threshold.fetchSub(1, moAcqRel)
        return
      if rq.threshold.fetchSub(1, moAcqRel) <= 0:
        return

proc newSCQueue*[T](): auto =
  doAssert sizeof(T) <= 8, "Queue can only handle pointers or objects less than or equal to 8 bytes"
  const sz = 1u shl (rqOrder + 1)
  result = SCQueue[T, sz](
    aqo: newEmptyRoonyQueue[T](),
    fqo: newFullRoonyQueue[T]()
  )

proc fq[T; N](sq: SCQueue[T, N]): var RoonyQueue[T, N] = sq.fqo
proc aq[T; N](sq: SCQueue[T, N]): var RoonyQueue[T, N] = sq.aqo

proc push*[T; N](sq: SCQueue[T, N]; val: T): bool =
  var eidx = sq.fq().pop(true)
  if eidx == high(uint):
    result = false
  else:
    sq.val[eidx] = val
    sq.aq().push(eidx, false)
    result = true

proc pop*[T; N](sq: SCQueue[T, N]): T =
  var eidx = sq.aq().pop(false)
  if not (eidx == high(uint)):
    result = sq.val[eidx]
    sq.fq().push(eidx, true)