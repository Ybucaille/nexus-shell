#include "audiocollector.hpp"

#include <qloggingcategory.h>

#include <pipewire/pipewire.h>

#include <algorithm>
#include <chrono>
#include <mutex>
#include <span>
#include <stop_token>
#include <thread>
#include <utility>
#include <vector>

#include "service.hpp"

namespace {

Q_LOGGING_CATEGORY(lcAcWorker, "caelestia.services.ac.worker", QtInfoMsg)

} // namespace

namespace caelestia::services {

PipeWireWorker::PipeWireWorker(std::stop_token token, AudioCollector* collector)
    : m_loop(nullptr)
    , m_stream(nullptr)
    , m_timer(nullptr)
    , m_quitEvent(nullptr)
    , m_idle(true)
    , m_token(std::move(token))
    , m_collector(collector) {
    pw_init(nullptr, nullptr);

    m_loop = pw_main_loop_new(nullptr);
    if (!m_loop) {
        qCWarning(lcAcWorker) << "init: failed to create PipeWire main loop";
        pw_deinit();
        return;
    }

    // Lets AudioCollector::stop() wake the loop from another thread, whatever the stream state
    m_quitEvent = pw_loop_add_event(
        pw_main_loop_get_loop(m_loop),
        [](void* data, uint64_t) {
            pw_main_loop_quit(static_cast<PipeWireWorker*>(data)->m_loop);
        },
        this);
    if (!m_quitEvent) {
        qCWarning(lcAcWorker) << "init: failed to create quit event";
        pw_main_loop_destroy(m_loop);
        pw_deinit();
        return;
    }

    timespec timeout = { .tv_sec = 0, .tv_nsec = 10 * SPA_NSEC_PER_MSEC };
    m_timer = pw_loop_add_timer(pw_main_loop_get_loop(m_loop), handleTimeout, this);
    if (!m_timer) {
        qCWarning(lcAcWorker) << "init: failed to create timer";
        pw_main_loop_destroy(m_loop);
        pw_deinit();
        return;
    }
    pw_loop_update_timer(pw_main_loop_get_loop(m_loop), m_timer, &timeout, &timeout, false);

    auto* props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE, "Music", nullptr);
    pw_properties_set(props, PW_KEY_STREAM_CAPTURE_SINK, "true");
    pw_properties_set(props, PW_KEY_NODE_PASSIVE, "true");
    pw_properties_set(props, PW_KEY_NODE_VIRTUAL, "true");
    pw_properties_set(props, PW_KEY_STREAM_DONT_REMIX, "false");
    pw_properties_set(props, "channelmix.upmix", "true");

    std::vector<uint8_t> buffer(ac::k_chunkSize);
    spa_pod_builder b;
    spa_pod_builder_init(&b, buffer.data(), static_cast<quint32>(buffer.size()));

    spa_audio_info_raw info{};
    info.format = SPA_AUDIO_FORMAT_S16;
    info.rate = ac::k_sampleRate;
    info.channels = 1;

    const spa_pod* params[1];
    params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);

    pw_stream_events events{};
    events.version = PW_VERSION_STREAM_EVENTS;
    events.state_changed = [](void* data, pw_stream_state, pw_stream_state state, const char*) {
        auto* self = static_cast<PipeWireWorker*>(data);
        self->streamStateChanged(state);
    };
    events.process = [](void* data) {
        auto* self = static_cast<PipeWireWorker*>(data);
        self->processStream();
    };

    m_stream = pw_stream_new_simple(pw_main_loop_get_loop(m_loop), "caelestia-shell", props, &events, this);
    if (!m_stream) {
        qCWarning(lcAcWorker) << "init: failed to create stream";
        pw_main_loop_destroy(m_loop);
        pw_deinit();
        return;
    }

    const int success = pw_stream_connect(m_stream, PW_DIRECTION_INPUT, PW_ID_ANY,
        static_cast<pw_stream_flags>(
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS),
        params, 1);
    if (success < 0) {
        qCWarning(lcAcWorker) << "init: failed to connect stream";
        pw_stream_destroy(m_stream);
        pw_main_loop_destroy(m_loop);
        pw_deinit();
        return;
    }

    collector->registerLoop(pw_main_loop_get_loop(m_loop), m_quitEvent);
    if (m_token.stop_requested()) {
        pw_loop_signal_event(pw_main_loop_get_loop(m_loop), m_quitEvent);
    }

    pw_main_loop_run(m_loop);

    collector->unregisterLoop();

    pw_stream_destroy(m_stream);
    pw_main_loop_destroy(m_loop);
    pw_deinit();
}

void PipeWireWorker::handleTimeout(void* data, uint64_t expirations) {
    auto* self = static_cast<PipeWireWorker*>(data);

    if (self->m_token.stop_requested()) {
        pw_main_loop_quit(self->m_loop);
        return;
    }

    if (!self->m_idle) {
        if (expirations < 10) {
            self->m_collector->clearBuffer();
        } else {
            self->m_idle = true;
            timespec timeout = { .tv_sec = 0, .tv_nsec = 500 * SPA_NSEC_PER_MSEC };
            pw_loop_update_timer(pw_main_loop_get_loop(self->m_loop), self->m_timer, &timeout, &timeout, false);
        }
    }
}

void PipeWireWorker::streamStateChanged(pw_stream_state state) {
    m_idle = false;
    switch (state) {
    case PW_STREAM_STATE_PAUSED: {
        timespec timeout = { .tv_sec = 0, .tv_nsec = 10 * SPA_NSEC_PER_MSEC };
        pw_loop_update_timer(pw_main_loop_get_loop(m_loop), m_timer, &timeout, &timeout, false);
        break;
    }
    case PW_STREAM_STATE_STREAMING:
        pw_loop_update_timer(pw_main_loop_get_loop(m_loop), m_timer, nullptr, nullptr, false);
        break;
    case PW_STREAM_STATE_ERROR:
        pw_main_loop_quit(m_loop);
        break;
    default:
        break;
    }
}

void PipeWireWorker::processStream() {
    if (m_token.stop_requested()) {
        pw_main_loop_quit(m_loop);
        return;
    }

    pw_buffer* const buffer = pw_stream_dequeue_buffer(m_stream);
    if (buffer == nullptr) {
        return;
    }

    const spa_buffer* buf = buffer->buffer;
    const auto* samples = reinterpret_cast<const qint16*>(buf->datas[0].data);
    if (samples != nullptr) {
        const quint32 count = buf->datas[0].chunk->size / sizeof(qint16);
        m_collector->loadChunk(samples, count);
    }

    pw_stream_queue_buffer(m_stream, buffer);
}

AudioCollector& AudioCollector::instance() {
    static AudioCollector s_instance;
    return s_instance;
}

void AudioCollector::clearBuffer() {
    const std::scoped_lock lock(m_samplesLock);
    m_samples.clear();
    m_discardPending.store(true, std::memory_order_release);
}

void AudioCollector::loadChunk(const qint16* samples, quint32 count) {
    if (m_discardPending.exchange(false, std::memory_order_acquire)) {
        m_pending.clear();
    }

    const auto toFloat = [](qint16 sample) {
        return static_cast<float>(sample) / 32768.0f;
    };

    // Called on the RT thread, so stash the chunk until the next callback rather than wait on a reader
    const std::unique_lock lock(m_samplesLock, std::try_to_lock);
    if (!lock.owns_lock()) {
        m_pending.push(std::span(samples, count), toFloat);
        return;
    }

    m_pending.pushTo(m_samples);
    m_pending.clear();
    m_samples.push(std::span(samples, count), toFloat);
}

template <typename T> quint32 AudioCollector::readLatest(T* out, quint32 count) {
    if (count == 0 || count > ac::k_chunkSize) {
        count = ac::k_chunkSize;
    }

    const std::span dest(out, count);
    const std::scoped_lock lock(m_samplesLock);

    // Pad the front with silence until the window has filled after a clear
    const auto available = static_cast<size_t>(std::min(m_samples.count(), static_cast<qsizetype>(count)));
    std::ranges::fill(dest.first(count - available), T(0));
    m_samples.copyLatest(dest.last(available), [](float sample) {
        return static_cast<T>(sample);
    });

    return count;
}

quint32 AudioCollector::readChunk(float* out, quint32 count) {
    return readLatest(out, count);
}

quint32 AudioCollector::readChunk(double* out, quint32 count) {
    return readLatest(out, count);
}

AudioCollector::AudioCollector(QObject* parent)
    : Service(parent)
    , m_samples(ac::k_chunkSize)
    , m_pending(ac::k_chunkSize)
    , m_discardPending(false) {}

AudioCollector::~AudioCollector() {
    AudioCollector::stop();
}

void AudioCollector::start() {
    if (m_thread.joinable()) {
        return;
    }

    clearBuffer();

    auto done = std::make_shared<std::atomic<bool>>(false);
    m_threadDone = done;
    m_thread = std::jthread([this, done](std::stop_token token) {
        {
            const PipeWireWorker worker(std::move(token), this);
        }
        done->store(true, std::memory_order_release);
    });
}

void AudioCollector::stop() {
    if (!m_thread.joinable()) {
        return;
    }

    m_thread.request_stop();
    wakeLoop();

    // Never block the caller (the UI thread) forever if the PipeWire loop does not return
    constexpr auto timeout = std::chrono::seconds(2);
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!m_threadDone->load(std::memory_order_acquire)) {
        if (std::chrono::steady_clock::now() >= deadline) {
            qCWarning(lcAcWorker) << "stop: PipeWire loop did not exit within" << timeout.count()
                                  << "s, detaching the thread";
            m_thread.detach();
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    m_thread.join();
}

void AudioCollector::registerLoop(pw_loop* loop, spa_source* quitEvent) {
    const std::lock_guard lock(m_loopMutex);
    m_loop = loop;
    m_quitEvent = quitEvent;
}

void AudioCollector::unregisterLoop() {
    const std::lock_guard lock(m_loopMutex);
    m_loop = nullptr;
    m_quitEvent = nullptr;
}

void AudioCollector::wakeLoop() {
    const std::lock_guard lock(m_loopMutex);
    if (m_loop && m_quitEvent) {
        pw_loop_signal_event(m_loop, m_quitEvent);
    }
}

} // namespace caelestia::services
