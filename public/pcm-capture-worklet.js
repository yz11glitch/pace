class PcmCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.active = true;
    this.buffer = new Float32Array(4096);
    this.length = 0;
    this.port.onmessage = (event) => {
      if (event.data === "stop") {
        this.active = false;
        this.flush();
        this.port.postMessage({ type: "stopped", sampleRate });
      }
    };
  }

  flush() {
    if (this.length === 0) return;
    const chunk = this.buffer.slice(0, this.length);
    this.port.postMessage({ type: "samples", samples: chunk }, [chunk.buffer]);
    this.length = 0;
  }

  process(inputs, outputs) {
    for (const output of outputs) {
      for (const channel of output) channel.fill(0);
    }

    const channels = inputs[0];
    if (!this.active || !channels?.[0]) return true;

    const frameCount = channels[0].length;
    for (let frame = 0; frame < frameCount; frame += 1) {
      let mono = 0;
      for (const channel of channels) mono += channel[frame] ?? 0;
      this.buffer[this.length] = mono / channels.length;
      this.length += 1;
      if (this.length === this.buffer.length) this.flush();
    }
    return true;
  }
}

registerProcessor("pcm-capture", PcmCaptureProcessor);
