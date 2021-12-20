import roony/spec
import roony/ring

type
  RoonyQueue*[T; N: static uint] = ref object
    ## Bounded circular queue which uses indirection to store and access values
    aqo: RingQueue[N]
    fqo: RingQueue[N]
    val: array[N, T]

proc newRoonyQueue*[T](): auto =
  ## Create and initialise a RoonyQueue.
  const sz = 1u shl (rqOrder + 1)

  result =
    RoonyQueue[T, sz](
      aqo: newEmptyRingQueue(),
      fqo: newFullRingQueue()
    )

# ----------------------------------------- #
# Accessors to internal ring queues as vars #
proc fq[T; N](sq: RoonyQueue[T, N]): var RingQueue[N] = sq.fqo
proc aq[T; N](sq: RoonyQueue[T, N]): var RingQueue[N] = sq.aqo
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