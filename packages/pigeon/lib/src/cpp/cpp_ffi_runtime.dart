// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Private, per-adapter runtime emitted inside an anonymous C++ namespace.
const String cppFfiRuntime = r'''
void PigeonFfiDestroyBuffer(PigeonFfiBuffer* buffer) {
  if (!buffer) return;
  delete[] buffer->data;
  delete buffer;
}

// Leases protect borrowed implementations while a call is executing. Closing
// a gate also waits for callback invocations to finish posting to Dart.
class PigeonFfiGate {
 public:
  struct Call {
    const PigeonFfiGate* gate;
    Call* previous;
  };
  bool Enter(Call* call) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!active_) return false;
    ++calls_;
    call->gate = this;
    call->previous = CurrentCall();
    CurrentCall() = call;
    return true;
  }
  void Leave(Call* call) {
    CurrentCall() = call->previous;
    std::lock_guard<std::mutex> lock(mutex_);
    if (--calls_ == 0) idle_.notify_all();
  }
  void Close() {
    for (auto* call = CurrentCall(); call; call = call->previous) {
      if (call->gate == this) {
        throw std::logic_error("Cannot close an FFI registration from its active call.");
      }
    }
    std::unique_lock<std::mutex> lock(mutex_);
    active_ = false;
    idle_.wait(lock, [this] { return calls_ == 0; });
  }
 private:
  // Leases are nested stack objects. Track reentrant calls without allocating
  // a map node on every entry; only this thread reads its active-call chain.
  static Call*& CurrentCall() {
    static thread_local Call* current = nullptr;
    return current;
  }
  std::mutex mutex_;
  std::condition_variable idle_;
  bool active_ = true;
  size_t calls_ = 0;
};

class PigeonFfiLease {
 public:
  explicit PigeonFfiLease(const std::shared_ptr<PigeonFfiGate>& gate)
      : gate_(gate) {
    if (gate_ && !gate_->Enter(&call_)) gate_.reset();
  }
  ~PigeonFfiLease() { if (gate_) gate_->Leave(&call_); }
  PigeonFfiLease(const PigeonFfiLease&) = delete;
  PigeonFfiLease& operator=(const PigeonFfiLease&) = delete;
  explicit operator bool() const { return gate_ != nullptr; }
 private:
  std::shared_ptr<PigeonFfiGate> gate_;
  PigeonFfiGate::Call call_;
};

template <typename T>
struct PigeonFfiRegistration {
  T* api;
  std::shared_ptr<PigeonFfiGate> gate = std::make_shared<PigeonFfiGate>();
  std::function<void(T*, const std::string&)> cancel;
  std::mutex streams_mutex;
  std::map<std::string, std::pair<int64_t, int64_t>> streams;
  std::set<std::pair<int64_t, int64_t>> cancelling;

  void Cancel(const std::vector<std::string>& names) {
    std::exception_ptr failure;
    for (const auto& name : names) {
      try {
        cancel(api, name);
      } catch (...) {
        if (!failure) failure = std::current_exception();
      }
    }
    if (failure) std::rethrow_exception(failure);
  }
};

template <typename T>
struct PigeonFfiSession {
  int64_t id;
  std::shared_ptr<PigeonFfiRegistration<T>> registration;
  std::shared_ptr<PigeonFfiGate> gate = std::make_shared<PigeonFfiGate>();

  void Listen(int64_t sink_id, const std::string& name) {
    std::lock_guard<std::mutex> lock(registration->streams_mutex);
    if (!registration->streams.emplace(name, std::make_pair(id, sink_id)).second) {
      throw std::invalid_argument("An FFI stream with this instance name is already listening.");
    }
  }
  std::optional<std::string> TakeStream(int64_t sink_id) {
    std::lock_guard<std::mutex> lock(registration->streams_mutex);
    for (auto it = registration->streams.begin(); it != registration->streams.end(); ++it) {
      if (it->second == std::make_pair(id, sink_id)) {
        if (!registration->cancelling.emplace(id, sink_id).second) return std::nullopt;
        return it->first;
      }
    }
    return std::nullopt;
  }
  void FinishStream(int64_t sink_id, const std::string& name) {
    std::lock_guard<std::mutex> lock(registration->streams_mutex);
    auto it = registration->streams.find(name);
    if (it != registration->streams.end() && it->second == std::make_pair(id, sink_id)) {
      registration->streams.erase(it);
    }
    registration->cancelling.erase(std::make_pair(id, sink_id));
  }
  template <typename F>
  void CancelStream(int64_t sink_id, F cancel) {
    auto name = TakeStream(sink_id);
    if (!name) return;
    try { cancel(*name); }
    catch (...) { FinishStream(sink_id, *name); throw; }
    FinishStream(sink_id, *name);
  }
};

template <typename T>
class PigeonFfiRegistry {
 public:
  using Session = PigeonFfiSession<T>;
  void SetUp(T* api, const std::string& name,
             std::function<void(T*, const std::string&)> cancel = nullptr) {
    if (!api) { TearDown(name); return; }
    std::lock_guard<std::mutex> lock(mutex_);
    if (registrations_.count(name)) {
      throw std::invalid_argument("FFI instance name is already registered; use a unique name for each engine.");
    }
    auto registration = std::make_shared<PigeonFfiRegistration<T>>();
    registration->api = api;
    registration->cancel = std::move(cancel);
    registrations_.emplace(name, std::move(registration));
  }
  int64_t Connect(const std::string& name) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = registrations_.find(name);
    if (it == registrations_.end()) {
      throw std::invalid_argument("No FFI implementation is registered with this instance name.");
    }
    if (next_id_ == std::numeric_limits<int64_t>::max()) {
      throw std::overflow_error("FFI session identifiers exhausted.");
    }
    const int64_t id = next_id_++;
    auto session = std::make_shared<Session>();
    session->id = id;
    session->registration = it->second;
    sessions_.emplace(id, std::move(session));
    return id;
  }
  std::shared_ptr<Session> Get(int64_t id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(id);
    return it == sessions_.end() ? nullptr : it->second;
  }
  void Disconnect(int64_t id) {
    auto session = Get(id);
    if (!session) return;
    session->gate->Close();
    auto registration = session->registration;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      sessions_.erase(id);
    }
    if (!registration->cancel) return;
    // Teardown owns any remaining streams if the registration is already closed.
    PigeonFfiLease lease(registration->gate);
    if (!lease) return;
    std::vector<std::string> names;
    {
      std::lock_guard<std::mutex> lock(registration->streams_mutex);
      for (auto it = registration->streams.begin(); it != registration->streams.end(); ++it) {
        if (it->second.first == id) {
          names.push_back(it->first);
        }
      }
    }
    std::exception_ptr failure;
    for (const auto& name : names) {
      try { registration->cancel(registration->api, name); }
      catch (...) { if (!failure) failure = std::current_exception(); }
      std::lock_guard<std::mutex> lock(registration->streams_mutex);
      auto it = registration->streams.find(name);
      if (it != registration->streams.end() && it->second.first == id) {
        registration->streams.erase(it);
      }
    }
    if (failure) std::rethrow_exception(failure);
  }
  void TearDown(const std::string& name) {
    std::shared_ptr<PigeonFfiRegistration<T>> registration;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = registrations_.find(name);
      if (it == registrations_.end()) return;
      registration = it->second;
    }
    registration->gate->Close();
    std::vector<std::string> names;
    {
      std::lock_guard<std::mutex> lock(registration->streams_mutex);
      for (const auto& entry : registration->streams) names.push_back(entry.first);
      registration->streams.clear();
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = registrations_.find(name);
      if (it != registrations_.end() && it->second == registration) registrations_.erase(it);
      for (auto session = sessions_.begin(); session != sessions_.end();) {
        if (session->second->registration == registration) session = sessions_.erase(session);
        else ++session;
      }
    }
    if (registration->cancel) registration->Cancel(names);
  }
 private:
  std::mutex mutex_;
  std::map<std::string, std::shared_ptr<PigeonFfiRegistration<T>>> registrations_;
  std::map<int64_t, std::shared_ptr<Session>> sessions_;
  int64_t next_id_ = 1;
};
''';
