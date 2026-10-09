import {
  pipeline,
  env
} from "https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.8.1/+esm";

const MODEL = "onnx-community/whisper-large-v3-turbo";

// Keep model files in the browser cache.
env.useBrowserCache = true;
env.allowRemoteModels = true;

let transcriber = null;
let mediaStream = null;
let mediaRecorder = null;
let audioChunks = [];

let loadPromise = null;
let inferenceDevice = "unknown";


function notifyProgress(message) {
  if (window.whisperFlutterProgress) {
    window.whisperFlutterProgress(message);
  }
}

async function loadModel() {
  if (transcriber) {
    return transcriber;
  }

  if (loadPromise) {
    return loadPromise;
  }

  loadPromise = (async () => {
    notifyProgress("Loading Whisper model...");

    let device = "wasm";

    if ("gpu" in navigator) {
      try {
        const adapter = await navigator.gpu.requestAdapter();

        if (adapter) {
          device = "webgpu";
        }
      } catch (e) {
        console.warn("WebGPU unavailable:", e);
      }
    }

    notifyProgress(
      device === "webgpu"
        ? "Loading Whisper with WebGPU..."
        : "Loading Whisper with browser CPU/WASM..."
    );

    /*
     * q4 is substantially smaller than the full precision model.
     *
     * Whisper is sensitive to quantization, so this sample intentionally
     * uses the q4 variant supplied by the official ONNX Community model
     * repository rather than trying to quantize the model ourselves.
     */
    inferenceDevice = device;

    window.whisperFlutterInferenceDevice = inferenceDevice;
    transcriber = await pipeline(
      "automatic-speech-recognition",
      MODEL,
      {
        device: device,
        dtype: "q4",

        progress_callback: (progress) => {
          if (!progress) {
            return;
          }

          if (progress.status === "progress") {
            const percent =
              typeof progress.progress === "number"
                ? Math.round(progress.progress)
                : null;

            if (percent !== null) {
              notifyProgress(
                `Downloading model: ${percent}%`
              );
            }
          } else if (progress.status === "done") {
            notifyProgress(
              `Loaded ${progress.file || "model file"}`
            );
          } else if (progress.status) {
            notifyProgress(progress.status);
          }
        }
      }
    );

    notifyProgress(
      device === "webgpu"
        ? "Whisper is ready (WebGPU)."
        : "Whisper is ready (WASM)."
    );

    return transcriber;
  })();

  try {
    return await loadPromise;
  } finally {
    loadPromise = null;
  }
}

/*
 * Convert the recorded browser audio into 16 kHz mono Float32 PCM.
 */
async function blobToFloat32Audio(blob) {
  const arrayBuffer = await blob.arrayBuffer();

  const audioContext = new AudioContext();

  try {
    const decoded = await audioContext.decodeAudioData(arrayBuffer);

    const channelCount = decoded.numberOfChannels;
    const sourceLength = decoded.length;

    let mono = new Float32Array(sourceLength);

    if (channelCount === 1) {
      mono.set(decoded.getChannelData(0));
    } else {
      for (let channel = 0; channel < channelCount; channel++) {
        const data = decoded.getChannelData(channel);

        for (let i = 0; i < sourceLength; i++) {
          mono[i] += data[i] / channelCount;
        }
      }
    }

    /*
     * Whisper expects 16 kHz audio.
     *
     * Offline/browser resampling is performed with an OfflineAudioContext.
     */
    if (decoded.sampleRate === 16000) {
      return mono;
    }

    const targetLength = Math.round(
      mono.length * 16000 / decoded.sampleRate
    );

    const offlineContext = new OfflineAudioContext(
      1,
      targetLength,
      16000
    );

    const buffer = offlineContext.createBuffer(
      1,
      mono.length,
      decoded.sampleRate
    );

    buffer.copyToChannel(mono, 0);

    const source = offlineContext.createBufferSource();
    source.buffer = buffer;
    source.connect(offlineContext.destination);
    source.start();

    const rendered = await offlineContext.startRendering();

    return rendered.getChannelData(0);
  } finally {
    await audioContext.close();
  }
}

async function startRecording() {
  if (mediaRecorder) {
    return;
  }

  if (!navigator.mediaDevices ||
      !navigator.mediaDevices.getUserMedia) {
    throw new Error(
      "This browser does not support microphone access."
    );
  }

  mediaStream = await navigator.mediaDevices.getUserMedia({
    audio: {
      channelCount: 1,
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true
    }
  });

  audioChunks = [];

  /*
   * Chrome normally supports audio/webm.
   */
  let mimeType = "";

  if (MediaRecorder.isTypeSupported("audio/webm;codecs=opus")) {
    mimeType = "audio/webm;codecs=opus";
  } else if (MediaRecorder.isTypeSupported("audio/webm")) {
    mimeType = "audio/webm";
  }

  mediaRecorder = mimeType
    ? new MediaRecorder(mediaStream, { mimeType })
    : new MediaRecorder(mediaStream);

  mediaRecorder.ondataavailable = (event) => {
    if (event.data && event.data.size > 0) {
      audioChunks.push(event.data);
    }
  };

  mediaRecorder.start();
}

async function stopRecording(language) {
  if (!mediaRecorder) {
    return "";
  }

  const recorder = mediaRecorder;

  const recordingFinished = new Promise((resolve, reject) => {
    recorder.onstop = () => resolve();
    recorder.onerror = (event) => {
      reject(event.error || new Error("MediaRecorder error."));
    };
  });

  recorder.stop();

  await recordingFinished;

  if (mediaStream) {
    for (const track of mediaStream.getTracks()) {
      track.stop();
    }
  }

  mediaStream = null;
  mediaRecorder = null;

  if (audioChunks.length === 0) {
    return "";
  }

  notifyProgress("Preparing audio...");

  const blob = new Blob(audioChunks, {
    type: recorder.mimeType || "audio/webm"
  });

  audioChunks = [];

  const audio = await blobToFloat32Audio(blob);

  if (!audio || audio.length === 0) {
    return "";
  }

  notifyProgress("Transcribing...");

  const pipe = await loadModel();

  const options = {
    chunk_length_s: 30,
    stride_length_s: 5,
    return_timestamps: false
  };

  /*
   * Auto language detection:
   * don't pass a language when "auto" is selected.
   *
   * Explicit language:
   * Transformers.js/Whisper expects the ISO language identifier.
   */
  if (language && language !== "auto") {
    options.language = language;
    options.task = "transcribe";
  }

  const result = await pipe(audio, options);

  const text =
    typeof result === "string"
      ? result
      : (result?.text || "");

  notifyProgress("Done.");

  return text.trim();
}

async function initialize() {
  await loadModel();
  return true;
}

window.whisperApp = {
  initialize,
  startRecording,
  stopRecording
};