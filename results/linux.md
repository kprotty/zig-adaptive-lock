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
std.Mutex     took 6 ms
AdaptiveMutex took 4 ms
Relative improvement: 1.50x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 65 ms
AdaptiveMutex took 25 ms
Relative improvement: 2.60x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 66 ms
AdaptiveMutex took 25 ms
Relative improvement: 2.64x
--------------------
10000000 Iterations
--------------------
std.Mutex     took 665 ms
AdaptiveMutex took 255 ms
Relative improvement: 2.61x
--------------------
100000000 Iterations
--------------------
std.Mutex     took 6616 ms
AdaptiveMutex took 2537 ms
Relative improvement: 2.61x
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
std.Mutex     took 53 ms
AdaptiveMutex took 22 ms
Relative improvement: 2.41x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 53 ms
AdaptiveMutex took 22 ms
Relative improvement: 2.41x
--------------------
10000000 Iterations
--------------------
std.Mutex     took 555 ms
AdaptiveMutex took 229 ms
Relative improvement: 2.42x
--------------------
100000000 Iterations
--------------------
std.Mutex     took 5544 ms
AdaptiveMutex took 2290 ms
Relative improvement: 2.42x
```