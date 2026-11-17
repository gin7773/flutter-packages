// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Runtime private to each generated C++ adapter.
const String cppFfiRuntime = r'''
void PigeonDestroyValue(PigeonCppValue* value) {
  if (!value) return;
  delete[] value->data;
  delete value;
}

// Closing waits for native entries and callback posts, never for async work.
class PigeonGate {
 public:
  struct Call {
    const PigeonGate* gate;
    Call* previous;
  };
  bool Enter(Call* call) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!active_) return false;
    ++calls_;
    call->gate = this;
    call->previous = Current();
    Current() = call;
    return true;
  }
  void Leave(Call* call) {
    Current() = call->previous;
    std::lock_guard<std::mutex> lock(mutex_);
    if (--calls_ == 0) idle_.notify_all();
  }
  void Close() {
    for (auto* call = Current(); call; call = call->previous) {
      if (call->gate == this) {
        throw std::logic_error("Cannot unregister from an active FFI call.");
      }
    }
    std::unique_lock<std::mutex> lock(mutex_);
    active_ = false;
    idle_.wait(lock, [this] { return calls_ == 0; });
  }

 private:
  static Call*& Current() {
    static thread_local Call* call = nullptr;
    return call;
  }
  std::mutex mutex_;
  std::condition_variable idle_;
  bool active_ = true;
  size_t calls_ = 0;
};

class PigeonLease {
 public:
  explicit PigeonLease(std::shared_ptr<PigeonGate> gate)
      : gate_(std::move(gate)) {
    if (gate_ && !gate_->Enter(&call_)) gate_.reset();
  }
  ~PigeonLease() {
    if (gate_) gate_->Leave(&call_);
  }
  PigeonLease(const PigeonLease&) = delete;
  PigeonLease& operator=(const PigeonLease&) = delete;
  explicit operator bool() const { return gate_ != nullptr; }

 private:
  std::shared_ptr<PigeonGate> gate_;
  PigeonGate::Call call_;
};

PigeonCppValue* PigeonBytes(const uint8_t* bytes, size_t length) {
  auto value = std::make_unique<PigeonCppValue>();
  value->length = length;
  if (length) {
    value->data = new uint8_t[length];
    std::memcpy(value->data, bytes, length);
  }
  return value.release();
}

PigeonCppValue* PigeonEncode(const flutter::StandardMessageCodec& codec,
                             const flutter::EncodableValue& value) {
  auto bytes = codec.EncodeMessage(value);
  return PigeonBytes(bytes->data(), bytes->size());
}

// Even allocation failure must not unwind through Dart's C ABI frames.
PigeonCppValue* PigeonError(const flutter::StandardMessageCodec& codec,
                            const flutter::EncodableValue& error) noexcept {
  try {
    auto* result = PigeonEncode(codec, error);
    result->is_error = 1;
    return result;
  } catch (...) {
    return nullptr;
  }
}
PigeonCppValue* PigeonException(const flutter::StandardMessageCodec& codec,
                                const char* message) noexcept {
  try {
    return PigeonError(codec, flutter::EncodableValue(flutter::EncodableList{
                                  flutter::EncodableValue("native-error"),
                                  flutter::EncodableValue(message),
                                  flutter::EncodableValue()}));
  } catch (...) {
    return nullptr;
  }
}

struct PigeonReply {
  std::atomic<bool> sent{false};
  int64_t id;
  PigeonCppReply callback;
  std::shared_ptr<PigeonGate> session_gate;
  const flutter::StandardMessageCodec* codec;
  void Send(PigeonCppValue* value) noexcept {
    PigeonLease lease(session_gate);
    if (!lease || sent.exchange(true)) {
      PigeonDestroyValue(value);
      return;
    }
    callback(id, value);
  }
  void Cancel() noexcept {
    Send(PigeonException(*codec, "FFI registration was removed."));
  }
};

template <typename T>
struct PigeonRegistration {
  int64_t id;
  T* api;  // Borrowed; the plugin owns and stops its asynchronous work.
  std::shared_ptr<PigeonGate> gate = std::make_shared<PigeonGate>();
};
template <typename T>
struct PigeonSession {
  std::shared_ptr<PigeonRegistration<T>> registration;
  std::shared_ptr<PigeonGate> gate = std::make_shared<PigeonGate>();
  std::mutex mutex;
  // Retain pending replies even if an implementation drops its callback.
  // Disposal must still post a terminal reply so Dart can drain the listener.
  std::vector<std::shared_ptr<PigeonReply>> replies;
  void Track(const std::shared_ptr<PigeonReply>& reply) {
    std::lock_guard<std::mutex> lock(mutex);
    replies.erase(
        std::remove_if(replies.begin(), replies.end(),
                       [](const auto& item) { return item->sent.load(); }),
        replies.end());
    replies.push_back(reply);
  }
  void Cancel() {
    std::lock_guard<std::mutex> lock(mutex);
    for (const auto& reply : replies) reply->Cancel();
    replies.clear();
  }
};

template <typename T>
class PigeonRegistry {
 public:
  using Session = PigeonSession<T>;
  int64_t Register(T* api, const std::string& name) {
    if (!api)
      throw std::invalid_argument("FFI implementation must not be null.");
    std::lock_guard<std::mutex> lock(mutex_);
    if (registrations_.count(name))
      throw std::invalid_argument("FFI name already registered.");
    auto registration = std::make_shared<PigeonRegistration<T>>();
    registration->id = NextId();
    registration->api = api;
    registrations_.emplace(name, registration);
    return registration->id;
  }
  int64_t Connect(const std::string& name) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = registrations_.find(name);
    if (it == registrations_.end())
      throw std::invalid_argument("No FFI registration with this name.");
    auto session = std::make_shared<Session>();
    session->registration = it->second;
    const auto id = NextId();
    sessions_.emplace(id, session);
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
    session->Cancel();
    session->gate->Close();
    std::lock_guard<std::mutex> lock(mutex_);
    sessions_.erase(id);
  }
  void Unregister(int64_t id) {
    std::shared_ptr<PigeonRegistration<T>> registration;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (const auto& entry : registrations_) {
        if (entry.second->id == id) {
          registration = entry.second;
          break;
        }
      }
    }
    if (!registration) return;
    registration->gate->Close();
    std::vector<std::shared_ptr<Session>> sessions;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (auto it = registrations_.begin(); it != registrations_.end(); ++it) {
        if (it->second == registration) {
          registrations_.erase(it);
          break;
        }
      }
      for (const auto& entry : sessions_) {
        if (entry.second->registration == registration)
          sessions.push_back(entry.second);
      }
    }
    // Keep each session discoverable until Dart disconnects it. In particular,
    // a concurrent disconnect must still fence an in-progress callback post.
    // Never hold the registry lock while waiting for entries or posts to
    // finish.
    for (const auto& session : sessions) {
      session->Cancel();
      session->gate->Close();
    }
  }

 private:
  int64_t NextId() {
    if (next_id_ == std::numeric_limits<int64_t>::max())
      throw std::overflow_error("FFI identifiers exhausted.");
    return next_id_++;
  }
  std::mutex mutex_;
  std::map<std::string, std::shared_ptr<PigeonRegistration<T>>> registrations_;
  std::map<int64_t, std::shared_ptr<Session>> sessions_;
  int64_t next_id_ = 1;
};
''';
