# Mesh vs Vision, live MacBook Air camera, same frames (no frames stored)

| | 15 fps | 30 fps |
|---|---|---|
| inference p50/p95 ms: Vision | 6.5 / 16.5 | 5.5 / 8.8 |
| inference p50/p95 ms: mesh CPU | 9.3 / 20.6 | 8.4 / 13.7 |
| inference p50/p95 ms: mesh CoreML EP | 18.5 / 50.7 | 18.4 / 26.7 |
| frame->pose p50/p95 ms (mesh CPU) | 51 / 145 | 47 / 92 |
| face found: Vision / mesh | 83% / 91% | 80% / 99% |
| rest jitter yaw deg: Vision / mesh | 0.54 / 0.80 | 0.31 / 0.51 |
| rest jitter eye dx: Vision / mesh | 0.009 / 0.019 | 0.008 / 0.015 |
| eye dx range seen: Vision / mesh | -0.11..0.28 / -0.64..0.94 | -0.15..0.29 / -0.33..0.74 |
| iris leads yaw (median) | 100 ms (n=13) | 201 ms (n=12) |

CPU EP is faster than CoreML for these small models. Run: `GlanceSwitch --mesh-bench --secs 60 --fps 15 --log f.log`.
