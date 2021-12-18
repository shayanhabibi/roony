import roony

type
  MyObj = ref object
    x: int

var q = newSCQueue[MyObj]()

var obj = MyObj(x: 1)
var obj2 = MyObj(x: 2)

echo repr q.pop()
echo q.push obj
echo repr q.pop()
echo q.push obj2
echo repr q.pop()
echo repr q.pop()
echo repr q.pop()