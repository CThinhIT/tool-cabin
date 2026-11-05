#pragma once

#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <mutex>
#include <thread>

namespace wa {

// One long-lived MTA thread for every control call (device lists, sessions, volume,
// device-change registration). The Dart caller thread may be an STA (the Flutter runner
// initializes COM as apartment-threaded), so COM objects are never touched from it.
class ComWorker {
public:
    ComWorker();
    ~ComWorker();
    ComWorker(const ComWorker&) = delete;
    ComWorker& operator=(const ComWorker&) = delete;

    // Runs fn on the worker thread and waits. Exceptions thrown by fn are rethrown here.
    void run(std::function<void()> fn);

private:
    void loop();

    std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<std::packaged_task<void()>> queue_;
    bool stopping_ = false;
    std::thread thread_;
};

}  // namespace wa
