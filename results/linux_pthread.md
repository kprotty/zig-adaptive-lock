System: Intel i7-6700k (4ghz, 4-core, hyperthreaded) - Arch Linux x86_64 Kernel 5.3.8
# Debug
```
--------------------
1000 Iterations
--------------------
std.Mutex     took 0 ms
AdaptiveMutex took 0 ms
Relative improvement: -nanx
--------------------
10000 Iterations
--------------------
std.Mutex     took 0 ms
AdaptiveMutex took 0 ms
Relative improvement: -nanx
--------------------
100000 Iterations
--------------------
std.Mutex     took 7 ms
AdaptiveMutex took 2 ms
Relative improvement: 3.50x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 71 ms
AdaptiveMutex took 26 ms
Relative improvement: 2.73x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 71 ms
AdaptiveMutex took 27 ms
Relative improvement: 2.63x
--------------------
10000000 Iterations
--------------------
std.Mutex     took 710 ms
AdaptiveMutex took 261 ms
Relative improvement: 2.72x
--------------------
100000000 Iterations
--------------------
std.Mutex     took 7128 ms
AdaptiveMutex took 2618 ms
Relative improvement: 2.72x
```

# ReleaseFast
```
--------------------
1000 Iterations
--------------------
std.Mutex     took 0 ms
AdaptiveMutex took 0 ms
Relative improvement: -nanx
--------------------
10000 Iterations
--------------------
std.Mutex     took 0 ms
AdaptiveMutex took 0 ms
Relative improvement: -nanx
--------------------
100000 Iterations
--------------------
std.Mutex     took 5 ms
AdaptiveMutex took 2 ms
Relative improvement: 2.50x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 52 ms
AdaptiveMutex took 24 ms
Relative improvement: 2.17x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 52 ms
AdaptiveMutex took 23 ms
Relative improvement: 2.26x
--------------------
10000000 Iterations
--------------------
std.Mutex     took 530 ms
AdaptiveMutex took 223 ms
Relative improvement: 2.38x
--------------------
100000000 Iterations
--------------------
std.Mutex     took 5324 ms
AdaptiveMutex took 2242 ms
Relative improvement: 2.37x
```