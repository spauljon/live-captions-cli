#  captions sequence
```
Main Queue                Core Audio Thread       Speech Callback Thread        Timer (Main)
    |                           |                        |                        |
    | start()                   |                        |                        |
    | installTap                |                        |                        |
    | audioEngine.start()       |                        |                        |
    | startNewSession() ------> |                        |                        |
    | startSilenceTimer()       |                        |                        |
    |                           | tap(buffer)            |                        |
    |                           | --> currentReq.append  |                        |
    |                           |                        | result/error callback  |
    |                           |                        | extract Strings        |
    |                           |                        | -----> main.async ---->|
    | <----- update latestFullText/lastChangeTime -------|                        |
    |                           |                        |                        |
    |                           |                        |                        | tick
    |                           |                        |                        | check stability
    |                           |                        |                        | if stable:
    |                           |                        |                        | emit final
    |                           |                        |                        | startNewSession()
    | startNewSessionOnMain()   |                        |                        |
    | token++                   |                        |                        |
    | currentReq=nil            |                        |                        |
    | cancel old task/request   |                        |                        |
    | new request/task          |                        |                        |
    | currentReq=newReq         |                        |                        |
    |                           | tap(buffer)            |                        |
    |                           | --> newReq.append      |                        |
```
