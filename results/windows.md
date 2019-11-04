System: Intel i7-6700k (4ghz, 4-core, hyperthreaded) - Windows 10 (1903)
# Debug
```
--------------------
1000 Iterations
--------------------
std.Mutex     took 1 ms
AdaptiveMutex took 1 ms
Relative improvement: 1.00x
--------------------
10000 Iterations
--------------------
std.Mutex     took 2 ms
AdaptiveMutex took 2 ms
Relative improvement: 1.00x
--------------------
100000 Iterations
--------------------
std.Mutex     took 20 ms
AdaptiveMutex took 3 ms
Relative improvement: 6.67x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 198 ms
AdaptiveMutex took 24 ms
Relative improvement: 8.25x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 199 ms
AdaptiveMutex took 24 ms
Relative improvement: 8.29x
--------------------
10000000 Iterations
--------------------
std.Mutex     took 1994 ms
AdaptiveMutex took 236 ms
Relative improvement: 8.45x
--------------------
100000000 Iterations
--------------------
std.Mutex     took 19750 ms
AdaptiveMutex took 2382 ms
Relative improvement: 8.29x
```

# ReleaseFast
```
--------------------
1000 Iterations
--------------------
std.Mutex     took 1 ms
AdaptiveMutex took 1 ms
Relative improvement: 1.00x
--------------------
10000 Iterations
--------------------
std.Mutex     took 2 ms
AdaptiveMutex took 1 ms
Relative improvement: 2.00x
--------------------
100000 Iterations
--------------------
std.Mutex     took 17 ms
AdaptiveMutex took 3 ms
Relative improvement: 5.67x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 164 ms
AdaptiveMutex took 22 ms
Relative improvement: 7.45x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 164 ms
AdaptiveMutex took 22 ms
Relative improvement: 7.45x
--------------------
10000000 Iterations
--------------------
std.Mutex     took 1580 ms
AdaptiveMutex took 215 ms
Relative improvement: 7.35x
--------------------
100000000 Iterations
--------------------
std.Mutex     took 16382 ms
AdaptiveMutex took 2092 ms
Relative improvement: 7.83x
```