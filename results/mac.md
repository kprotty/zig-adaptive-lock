System: Intel Core i9 (2.4ghz, 4-core, hyperthreaded) - macOS Catalina 10.15.1 Beta (19B77a)
# Debug
```
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