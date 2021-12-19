import roony

type
  MyObj = ref object
    x: int

var q = newRoonyQueue[MyObj]()

echo repr q.pop

var counter1: int
for i in 0..<1_000:
  var obj = MyObj(x: i)
  if q.push obj:
    inc counter1
echo counter1

var counter: int
while q.pop != nil:
  inc counter

echo counter
