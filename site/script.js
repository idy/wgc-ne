(() => {
  "use strict";

  const board = document.getElementById("runtime-board");
  if (!board) return;

  const stages = Array.from(board.querySelectorAll("[data-stage]"));
  const stageOrder = stages.map((button) => button.dataset.stage);
  const nextButton = document.getElementById("flow-next");
  const transportChoice = document.getElementById("transport-choice");
  const copyStatus = document.getElementById("copy-status");
  let activeStage = "flutter";
  let activeTransport = "udp";

  const descriptions = {
    flutter: {
      owner: "App process",
      title: "Flutter owns the controls.",
      description: "The plugin controls an owned NETunnelProviderManager through native code and reads status through provider messages. Packet data does not pass through the Flutter engine."
    },
    ne: {
      owner: "Swift provider",
      title: "NetworkExtension owns the tunnel.",
      description: "Your embedded PacketTunnel extension applies the platform’s network settings. The Swift provider passes a duplicate utun descriptor to the Go core. The provider runs without a Flutter engine."
    },
    singbox: {
      owner: "Go core / IP flows",
      title: "sing-box handles TCP, UDP, and DNS.",
      description: "sing-box v1.14.4 handles TUN flows, userspace TCP/UDP, DNS, and routing. The default policy sends these flows through the selected WGC peer. NetworkExtension owns OS route installation."
    },
    wgc: {
      owner: "Go core / WGC v0.2.0",
      title: "WGC exchanges WireGuard packets.",
      description: "WGC handles authenticated WireGuard messages. Its Transport interface reads and writes one message at a time, keeping the packet carrier replaceable inside your Go core."
    }
  };

  const transports = {
    udp: {
      name: "Standard UDP",
      meta: "Included adapter",
      caption: "Shipped in the SDK",
      config: '{"type":"udp","options":{}}',
      owner: "Go core / included transport",
      title: "Standard UDP is ready to plug in.",
      description: "The SDK includes a standard UDP transport for WireGuard messages. UDP is the default when transport is omitted. The sample configuration below uses this included adapter."
    },
    custom: {
      name: "Your Go wrapper",
      meta: "Compiled into your core",
      caption: "Illustrative name; register it in your Go build",
      config: '{"type":"your-registered-name","options":{}}',
      owner: "Go core / your compiled transport",
      title: "Your wrapper lives in the native core.",
      description: "Compile your private transport factory or wrapper into the extension’s Go core. Flutter sends its registered name and JSON options, without per-packet callbacks. Unknown names fail closed. The name shown here is illustrative."
    }
  };

  function selectStage(name) {
    if (!stageOrder.includes(name)) return;
    activeStage = name;
    const info = name === "transport" ? transports[activeTransport] : descriptions[name];
    stages.forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.stage === name));
    });
    document.getElementById("flow-owner").textContent = info.owner;
    document.getElementById("flow-title").textContent = info.title;
    document.getElementById("flow-description").textContent = info.description;
    document.getElementById("flow-position").textContent = `Stage ${stageOrder.indexOf(name) + 1} of ${stageOrder.length}`;
    nextButton.firstChild.nodeValue = name === "transport" ? "Back to Flutter " : "Next stage ";
  }

  function selectTransport(name) {
    if (!Object.prototype.hasOwnProperty.call(transports, name)) return;
    activeTransport = name;
    const info = transports[name];
    board.dataset.transport = name;
    document.getElementById("transport-name").textContent = info.name;
    document.getElementById("transport-meta").textContent = info.meta;
    document.getElementById("socket-caption").textContent = info.caption;
    document.getElementById("socket-config").textContent = info.config;
    selectStage("transport");

    board.classList.remove("is-swapping");
    if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      // Restart a single, user-triggered seating motion at the transport socket.
      void board.offsetWidth;
      board.classList.add("is-swapping");
    }
  }

  stages.forEach((button) => {
    button.disabled = false;
    button.addEventListener("click", () => selectStage(button.dataset.stage));
  });
  transportChoice.disabled = false;
  transportChoice.addEventListener("change", (event) => {
    const input = event.target;
    if (input.name === "transport" && input.checked) selectTransport(input.value);
  });
  board.addEventListener("animationend", () => board.classList.remove("is-swapping"));
  nextButton.hidden = false;
  nextButton.addEventListener("click", () => {
    const index = (stageOrder.indexOf(activeStage) + 1) % stageOrder.length;
    selectStage(stageOrder[index]);
  });

  function fallbackCopy(text) {
    const previousFocus = document.activeElement;
    const input = document.createElement("textarea");
    input.value = text;
    input.setAttribute("readonly", "");
    input.setAttribute("aria-label", "Code to copy");
    input.style.cssText = "position:fixed;left:-9999px;top:0;";
    document.body.appendChild(input);
    let copied = false;
    try {
      input.select();
      copied = document.execCommand("copy");
    } finally {
      input.remove();
      if (previousFocus && typeof previousFocus.focus === "function") {
        previousFocus.focus({ preventScroll: true });
      }
    }
    return copied;
  }

  const copyTimers = new WeakMap();
  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.hidden = false;
    const label = button.dataset.copy === "config-code" ? "JSON configuration" : "Go transport interface";
    button.setAttribute("aria-label", `Copy ${label}`);
    button.addEventListener("click", async () => {
      const code = document.getElementById(button.dataset.copy);
      if (!code) return;
      window.clearTimeout(copyTimers.get(button));
      let copied = false;
      if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
        try {
          await navigator.clipboard.writeText(code.textContent);
          copied = true;
        } catch {
          // file:// previews and older browsers may require the local fallback.
        }
      }
      if (!copied) {
        try {
          copied = fallbackCopy(code.textContent);
        } catch {
          copied = false;
        }
      }
      button.textContent = copied ? "Copied" : "Select code";
      copyStatus.textContent = copied
        ? `${label} copied.`
        : `Copy is unavailable here. Select the ${label} and copy it manually.`;
      copyTimers.set(button, window.setTimeout(() => {
        button.textContent = "Copy";
      }, 2200));
    });
  });
})();
