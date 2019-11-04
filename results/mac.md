System: Intel Core i9 (2.4ghz, 4-core, hyperthreaded) - macOS Catalina 10.15.1 Beta (19B77a)
# Debug
```
--------------------
1000 Iterations
--------------------
std.Mutex     took 1 ms
AdaptiveMutex took 0 ms
Relative improvement: infx
--------------------
10000 Iterations
--------------------
std.Mutex     took 10 ms
AdaptiveMutex took 0 ms
Relative improvement: infx
--------------------
100000 Iterations
--------------------
std.Mutex     took 90 ms
AdaptiveMutex took 4 ms
Relative improvement: 22.50x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 984 ms
AdaptiveMutex took 43 ms
Relative improvement: 22.88x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 963 ms
AdaptiveMutex took 42 ms
Relative improvement: 22.93x
--------------------
10000000 Iterations
--------------------
std.Mutex     took 9021 ms
AdaptiveMutex took 422 ms
Relative improvement: 21.38x
--------------------
100000000 Iterations
--------------------
std.Mutex     took 99959 ms
AdaptiveMutex took 4410 ms
Relative improvement: 22.67x
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
std.Mutex     took 6 ms
AdaptiveMutex took 0 ms
Relative improvement: infx
--------------------
100000 Iterations
--------------------
std.Mutex     took 68 ms
AdaptiveMutex took 3 ms
Relative improvement: 22.67x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 715 ms
AdaptiveMutex took 34 ms
Relative improvement: 21.03x
--------------------
1000000 Iterations
--------------------
std.Mutex     took 715 ms
AdaptiveMutex took 36 ms
Relative improvement: 19.86x
--------------------
10000000 Iterations
--------------------
std.Mutex     took 6326 ms
AdaptiveMutex took 343 ms
Relative improvement: 18.44x
--------------------
100000000 Iterations
--------------------
std.Mutex     took 65187 ms
AdaptiveMutex took 3392 ms
Relative improvement: 19.22x
```