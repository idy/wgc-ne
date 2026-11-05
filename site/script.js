(() => {
  "use strict";
  if (!window.IdySite) return;

  // Keep English in the HTML as a complete, readable no-JavaScript fallback.
  const en = {
    pageTitle: "WGC NE — Flutter control. Native packet path.",
    description: "An independent Flutter plugin and Apple Network Extension SDK. sing-box handles IP flows, WGC handles WireGuard packets, and your Go core owns the transport.",
    socialDescription: "A Flutter plugin and Go SDK for an Apple PacketTunnel extension you embed and sign. Explore the transport boundary.",
    releaseLoading: "Checking GitHub for the latest release…",
    releaseStable: "Latest stable release",
    releasePreview: "Latest preview release",
    releaseFailed: "Release information is unavailable. Browse GitHub Releases for the latest downloads.",
    releaseAssetsMissing: "No matching XCFramework was published with this release. See the release notes for build instructions.",
    flutterOwner: "App process",
    flutterTitle: "Flutter owns the controls.",
    flutterDescription: "The plugin controls an owned NETunnelProviderManager through native code and reads status through provider messages. Packet data does not pass through the Flutter engine.",
    neOwner: "Swift provider",
    neTitle: "NetworkExtension owns the tunnel.",
    neDescription: "Your embedded PacketTunnel extension applies the platform’s network settings. The Swift provider passes a duplicate utun descriptor to the Go core. The provider runs without a Flutter engine.",
    singboxOwner: "Go core / IP flows",
    singboxTitle: "sing-box handles TCP, UDP, and DNS.",
    singboxDescription: "sing-box v1.14.4 handles TUN flows, userspace TCP/UDP, DNS, and routing. The default policy sends these flows through the selected WGC peer. NetworkExtension owns OS route installation.",
    wgcOwner: "Go core / WGC v0.2.0",
    wgcTitle: "WGC exchanges WireGuard packets.",
    wgcDescription: "WGC handles authenticated WireGuard messages. Its Transport interface reads and writes one message at a time, keeping the packet carrier replaceable inside your Go core.",
    udpMeta: "Included adapter",
    udpCaption: "Shipped in the SDK",
    udpOwner: "Go core / included transport",
    udpTitle: "Standard UDP is ready to plug in.",
    udpDescription: "The SDK includes a standard UDP transport for WireGuard messages. UDP is the default when transport is omitted. The sample configuration below uses this included adapter.",
    customMeta: "Compiled into your core",
    customCaption: "Illustrative name; register it in your Go build",
    customOwner: "Go core / your compiled transport",
    customTitle: "Your wrapper lives in the native core.",
    customDescription: "Compile your private transport factory or wrapper into the extension’s Go core. Flutter sends its registered name and JSON options, without per-packet callbacks. Unknown names fail closed. The name shown here is illustrative.",
    stagePosition: "Stage {current} of {total}",
    nextStage: "Next stage",
    backToFlutter: "Back to Flutter",
    copy: "Copy",
    copied: "Copied",
    selectCode: "Select code",
    copySource: "Code to copy",
    copyTransport: "Copy Go transport interface",
    copyConfig: "Copy JSON configuration",
    copiedTransport: "Go transport interface copied.",
    copiedConfig: "JSON configuration copied.",
    copyFailed: "Copy is unavailable here. Select the code and copy it manually."
  };
  for (const [attribute, read] of [
    ["data-i18n", (node) => node.textContent],
    ["data-i18n-html", (node) => node.innerHTML],
    ["data-i18n-aria-label", (node) => node.getAttribute("aria-label")]
  ]) {
    document.querySelectorAll(`[${attribute}]`).forEach((node) => {
      en[node.getAttribute(attribute)] = read(node);
    });
  }

  IdySite.init({ en, zh: {
    pageTitle: "WGC NE — Flutter 控制，原生数据通路。",
    description: "独立开发的 Flutter 插件与 Apple Network Extension SDK。sing-box 处理 IP 流量，WGC 处理 WireGuard 数据包，你的 Go 核心负责传输。",
    socialDescription: "用于 Apple PacketTunnel 扩展的 Flutter 插件与 Go SDK，由你的应用嵌入并签名。了解传输层的职责边界。",
    starLabel: "在 GitHub 为 WGC NE 点星（在新标签页打开）",
    architecture: "架构",
    transport: "传输层",
    integration: "集成",
    productKind: "Flutter 插件 + Apple Network Extension SDK",
    heroTitle: "Flutter 控制。<br>原生数据通路。",
    heroIntro: "属于你应用的隧道，可以自由替换的传输层。",
    heroBody: "WGC NE 将 Flutter 应用连接到它自己的 PacketTunnel 扩展。sing-box 在 Go 中处理 IP 流量，WGC 处理经过身份验证的 WireGuard 数据包。",
    readReadme: "阅读项目 README",
    previewLabel: "API 预览版",
    previewNote: "构建工具和 Dart API 可能发生变化。请以<a href=\"https://github.com/idy/wgc-ne/blob/main/docs/architecture.md\">架构文档</a>中的当前接口约定为准。",
    downloadTitle: "获取原生核心。",
    downloadIntro: "下载已发布的 XCFramework，或构建自己的核心以集成自定义传输层。",
    releaseFallback: "在 GitHub Releases 中查看当前版本和可用下载。",
    releaseLoading: "正在从 GitHub 获取最新版本…",
    releaseStable: "最新稳定版",
    releasePreview: "最新预览版",
    releaseFailed: "暂时无法获取版本信息。请前往 GitHub Releases 查看最新下载。",
    releaseAssetsMissing: "此版本未发布匹配的 XCFramework。请查看版本说明中的构建指南。",
    downloadCore: "下载 XCFramework",
    checksums: "SHA-256 校验文件",
    downloadNote: "你的应用仍需嵌入并签名自己的 PacketTunnel 扩展。仅添加 Flutter 依赖无法完成扩展的配置与签名。",
    architectureTitle: "查看你的传输层接在哪里。",
    architectureIntro: "选择一个阶段，了解它的职责边界。",
    flowHeading: "控制调用与数据流",
    legendLabel: "示意图图例",
    controlCall: "控制调用",
    packetPath: "IP / 数据包通路",
    containingApp: "宿主应用",
    flutterProcess: "Flutter 引擎在此运行",
    profileStatus: "配置 + 状态",
    yourExtension: "你的 PacketTunnel 扩展",
    embeddedSigned: "由你的应用嵌入并签名",
    neMeta: "TUN + Swift 提供程序",
    wgcMeta: "WireGuard 数据包",
    transportSocket: "传输层插槽",
    udpName: "标准 UDP",
    customName: "你的 Go 包装器",
    flutterOwner: "应用进程",
    flutterTitle: "Flutter 负责控制。",
    flutterDescription: "插件通过原生代码控制本应用的 NETunnelProviderManager，并通过提供程序消息读取状态。数据包不经过 Flutter 引擎。",
    neOwner: "Swift 提供程序",
    neTitle: "NetworkExtension 负责隧道。",
    neDescription: "应用内嵌的 PacketTunnel 扩展应用平台网络设置。Swift 提供程序将复制的 utun 描述符传给 Go 核心，运行时不需要 Flutter 引擎。",
    singboxOwner: "Go 核心 / IP 流量",
    singboxTitle: "sing-box 处理 TCP、UDP 和 DNS。",
    singboxDescription: "sing-box v1.14.4 处理 TUN 流量、用户态 TCP/UDP、DNS 和路由。默认策略将这些流量发送到选定的 WGC 对端。操作系统路由由 NetworkExtension 安装。",
    wgcOwner: "Go 核心 / WGC v0.2.0",
    wgcTitle: "WGC 交换 WireGuard 数据包。",
    wgcDescription: "WGC 处理经过身份验证的 WireGuard 消息。它的 Transport 接口每次读写一条消息，让你可以在 Go 核心中替换数据包的传输方式。",
    udpMeta: "内置适配器",
    udpCaption: "SDK 内置",
    udpOwner: "Go 核心 / 内置传输层",
    udpTitle: "标准 UDP 即插即用。",
    udpDescription: "SDK 内置用于 WireGuard 消息的标准 UDP 传输层。省略 transport 配置时默认使用 UDP，下方示例配置也使用这个内置适配器。",
    customMeta: "编译进你的核心",
    customCaption: "示意名称；请在 Go 构建中注册",
    customOwner: "Go 核心 / 自行编译的传输层",
    customTitle: "你的包装器运行在原生核心中。",
    customDescription: "将私有传输工厂或包装器编译进扩展的 Go 核心。Flutter 只传递已注册的名称和 JSON 选项，不参与逐包回调。未知名称会直接失败。此处的名称仅作示意。",
    stagePosition: "第 {current} 阶段，共 {total} 阶段",
    nextStage: "下一阶段",
    backToFlutter: "返回 Flutter",
    diagramFootnote: "图中展示出站方向。这是交互式架构示意图，不会发送网络流量。",
    transportContext: "传输层的职责边界",
    transportTitle: "三个方法。<br>承载你的数据包。",
    transportIntro: "Go 核心依赖 <a href=\"https://github.com/idy/wgc/tree/v0.2.0\">WGC v0.2.0</a>。其传输接口与远端端点交换 WireGuard 消息。",
    transportScope: "内置的只有标准 UDP。私有认证、中继、封装或混淆逻辑应放在包装器中，并编译进你的 Go 核心。",
    exploreWgc: "了解 WGC 项目",
    transportCodeLabel: "WGC v0.2.0 Transport 接口",
    concurrency: "并发",
    concurrencyBody: "一个读取方，多个并发写入方。",
    buffers: "缓冲区",
    buffersBody: "方法返回后，不要继续持有缓冲区。",
    lifecycle: "生命周期",
    lifecycleBody: "Close 会解除等待中的 I/O 阻塞。",
    referenceNote: "在扩展核心中注册自定义工厂。Flutter 选择已注册的名称和 JSON 选项；未知名称会直接失败。",
    configurationContext: "配置版本 1",
    configurationTitle: "用 JSON 明确约定。",
    readSchema: "阅读结构定义与默认值",
    configurationHeading: "标准 UDP 配置",
    configCodeLabel: "文档中的版本 1 配置示例",
    exampleNote: "示例来自架构文档。请替换密钥占位符，并使用远端 WireGuard 服务器允许的地址。",
    requiredInputs: "必填输入",
    requiredInputsBody: "<code>version</code>、<code>private_key</code>、<code>addresses</code> 和 <code>peers</code>。端点和解析器必须使用 IP 地址，不得包含区域标识。",
    platformRoutes: "路由由平台负责",
    platformRoutesBody: "NetworkExtension 安装网络设置。核心会将各对端外层端点的主机路由加入排除列表。",
    deviceCredentials: "凭据保留在设备上",
    deviceCredentialsBody: "配置保存在共享访问组内、仅限本设备的 Keychain 项中。偏好设置只保留配置引用，不保存私钥或完整配置。",
    singboxScopeTitle: "sing-box 的职责清晰明确。",
    singboxScopeBody: "默认策略将 TUN 的 TCP/UDP 和 DNS 流量发往选定的对端。原始 ICMP 转发不在用户态出站模块声明的范围内。",
    registrations: "SDK 内置的注册组件",
    integrationContext: "集成职责",
    integrationTitle: "你的应用，<br>携带自己的扩展。",
    integrationIntro: "共享 SDK 和原生 ABI。每个宿主应用都嵌入并签名自己的 PacketTunnel 目标，保留独立的 VPN 身份。",
    startReadme: "从 README 开始",
    architectureContracts: "架构与接口约定",
    containingAppBody: "负责界面、账号、API 集成和策略。通过 Flutter 插件管理原生配置并读取状态。",
    packetTunnelTarget: "PacketTunnel 目标",
    packetTunnelBody: "运行 Swift 和 Go，无需 Flutter 引擎。链接你选择的 <code>WGCCore.xcframework</code>，设置 NetworkExtension 权限及匹配的共享 Keychain 权限。",
    customCore: "自定义 Go 核心",
    customCoreBody: "将私有传输工厂和包装器编译进这个二进制文件。JSON 中的传输名称选择的是构建时已注册的代码。",
    contractLabel: "依据当前接口约定构建",
    contractNote: "此 SDK 仍为 API 预览版。请关注仓库中的最新构建工具和 Dart 集成方式，公开接口可能发生变化。",
    independentNote: "本项目独立开发，不是 WireGuard 或 sing-box 的官方应用。",
    licenseNote: "GPL-3.0-or-later。请保留 WGC 的 MIT 署名，以及 sing-box 的许可证和声明。各依赖的许可证仍然适用。",
    copy: "复制",
    copied: "已复制",
    selectCode: "选择代码",
    copySource: "待复制的代码",
    copyTransport: "复制 Go 传输接口",
    copyConfig: "复制 JSON 配置",
    copiedTransport: "已复制 Go 传输接口。",
    copiedConfig: "已复制 JSON 配置。",
    copyFailed: "当前无法自动复制。请选择代码并手动复制。"
  } });

  const t = (key) => IdySite.t(key);
  const board = document.getElementById("runtime-board");
  const stages = Array.from(board.querySelectorAll("[data-stage]"));
  const stageOrder = stages.map((button) => button.dataset.stage);
  const nextButton = document.getElementById("flow-next");
  const transportChoice = document.getElementById("transport-choice");
  const copyStatus = document.getElementById("copy-status");
  const copyButtons = Array.from(document.querySelectorAll("[data-copy]"));
  const copyStates = new WeakMap();
  const copyTimers = new WeakMap();
  let activeStage = "flutter";
  let activeTransport = "udp";
  let copyMessage = "";
  let release;
  let releaseState = "loading";
  let hasCoreAsset = false;

  const transportConfigs = {
    udp: '{"type":"udp","options":{}}',
    custom: '{"type":"your-registered-name","options":{}}'
  };

  function renderStage() {
    const prefix = activeStage === "transport" ? activeTransport : activeStage;
    stages.forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.stage === activeStage));
    });
    document.getElementById("flow-owner").textContent = t(`${prefix}Owner`);
    document.getElementById("flow-title").textContent = t(`${prefix}Title`);
    document.getElementById("flow-description").textContent = t(`${prefix}Description`);
    document.getElementById("flow-position").textContent = t("stagePosition")
      .replace("{current}", stageOrder.indexOf(activeStage) + 1).replace("{total}", stageOrder.length);
    document.getElementById("flow-next-label").textContent = t(activeStage === "transport" ? "backToFlutter" : "nextStage");
  }

  function renderTransport() {
    document.getElementById("transport-name").textContent = t(`${activeTransport}Name`);
    document.getElementById("transport-meta").textContent = t(`${activeTransport}Meta`);
    document.getElementById("socket-caption").textContent = t(`${activeTransport}Caption`);
    document.getElementById("socket-config").textContent = transportConfigs[activeTransport];
  }

  function selectStage(name) {
    if (!stageOrder.includes(name)) return;
    activeStage = name;
    renderStage();
  }

  function selectTransport(name) {
    if (!Object.prototype.hasOwnProperty.call(transportConfigs, name)) return;
    activeTransport = name;
    board.dataset.transport = name;
    renderTransport();
    selectStage("transport");
    board.classList.remove("is-swapping");
    if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      // Restart a single, user-triggered seating motion at the transport socket.
      void board.offsetWidth;
      board.classList.add("is-swapping");
    }
  }

  function renderCopy() {
    copyButtons.forEach((button) => {
      button.textContent = t(copyStates.get(button) || "copy");
      button.setAttribute("aria-label", t(button.dataset.copy === "config-code" ? "copyConfig" : "copyTransport"));
    });
    copyStatus.textContent = copyMessage ? t(copyMessage) : "";
  }

  function renderRelease() {
    let message;
    if (releaseState === "loaded") {
      message = t(release.prerelease ? "releasePreview" : "releaseStable");
      if (!hasCoreAsset) message += ` — ${t("releaseAssetsMissing")}`;
    } else {
      message = t(releaseState === "failed" ? "releaseFailed" : "releaseLoading");
    }
    document.getElementById("release-status").textContent = message;
  }

  function renderMetadata() {
    document.title = t("pageTitle");
    document.querySelector('meta[name="description"]').content = t("description");
    document.querySelector('meta[property="og:title"]').content = t("pageTitle");
    document.querySelector('meta[property="og:description"]').content = t("socialDescription");
    document.querySelector('meta[name="theme-color"]').content = document.documentElement.dataset.theme === "dark" ? "#101a29" : "#f3f6fb";
  }

  function renderLanguage() {
    renderMetadata();
    renderStage();
    renderTransport();
    renderCopy();
    renderRelease();
  }
  document.addEventListener("idy:languagechange", renderLanguage);
  new MutationObserver(renderMetadata).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  renderLanguage();

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
    input.setAttribute("aria-label", t("copySource"));
    input.style.cssText = "position:fixed;left:-9999px;top:0;";
    document.body.appendChild(input);
    try {
      input.select();
      return document.execCommand("copy");
    } finally {
      input.remove();
      previousFocus?.focus({ preventScroll: true });
    }
  }

  copyButtons.forEach((button) => {
    button.hidden = false;
    button.addEventListener("click", async () => {
      const code = document.getElementById(button.dataset.copy);
      if (!code) return;
      window.clearTimeout(copyTimers.get(button));
      let copied = false;
      if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
        try {
          await navigator.clipboard.writeText(code.textContent);
          copied = true;
        } catch { /* Try the local selection fallback. */ }
      }
      if (!copied) {
        try { copied = fallbackCopy(code.textContent); } catch { /* Report manual copy below. */ }
      }
      copyStates.set(button, copied ? "copied" : "selectCode");
      copyMessage = copied
        ? (button.dataset.copy === "config-code" ? "copiedConfig" : "copiedTransport")
        : "copyFailed";
      renderCopy();
      copyTimers.set(button, window.setTimeout(() => {
        copyStates.delete(button);
        renderCopy();
      }, 2200));
    });
  });

  IdySite.loadRelease("idy/wgc-ne").then((latest) => {
    release = latest;
    releaseState = "loaded";
    const version = document.getElementById("release-version");
    version.textContent = release.tag_name;
    version.hidden = false;
    document.getElementById("release-link").href = release.html_url;
    const core = IdySite.asset(release, /^WGCCore-.+\.xcframework\.zip$/i);
    const checksums = IdySite.asset(release, /^SHA256SUMS(?:\.txt)?$/i);
    hasCoreAsset = Boolean(core);
    for (const [id, asset] of [["core-download", core], ["checksum-download", checksums]]) {
      if (!asset) continue;
      const link = document.getElementById(id);
      link.href = asset.browser_download_url;
      link.hidden = false;
    }
    renderRelease();
  }).catch(() => {
    releaseState = "failed";
    renderRelease();
  });
})();
