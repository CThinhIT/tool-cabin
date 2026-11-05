#include "com_worker.h"

#include "common.h"

namespace wa {

ComWorker::ComWorker() : thread_([this] { loop(); }) {}

ComWorker::~ComWorker() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
}

void ComWorker::run(std::function<void()> fn) {
    if (std::this_thread::get_id() == thread_.get_id()) {
        fn();
        return;
    }
    std::packaged_task<void()> task(std::move(fn));
    auto done = task.get_future();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) throw WaError("win_audio is shutting down");
        queue_.push_back(std::move(task));
    }
    cv_.notify_one();
    done.get();
}

void ComWorker::loop() {
    ComInit com;
    for (;;) {
        std::packaged_task<void()> task;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
            if (queue_.empty()) return;  // stopping and drained
            task = std::move(queue_.front());
            queue_.pop_front();
        }
        task();
    }
}

}  // namespace wa
