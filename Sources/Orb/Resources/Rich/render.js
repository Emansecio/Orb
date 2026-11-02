// The page `RichRenderer` keeps hidden: it draws one diagram or formula at a time and says how large it came out.
mermaid.initialize({
  startOnLoad: false,
  securityLevel: "strict",
  suppressErrorRendering: true,
  maxTextSize: 32768,
  maxEdges: 400,
  theme: "base",
  flowchart: { useMaxWidth: false },
  sequence: { useMaxWidth: false },
  gantt: { useMaxWidth: false },
  class: { useMaxWidth: false },
  state: { useMaxWidth: false },
  er: { useMaxWidth: false },
  pie: { useMaxWidth: false },
  journey: { useMaxWidth: false },
  fontFamily: "-apple-system, sans-serif",
  themeVariables: {
    darkMode: true,
    background: "#222222",
    fontFamily: "-apple-system, sans-serif",
    fontSize: "14px",
    primaryColor: "#2E2E2E",
    primaryTextColor: "#FCFCFC",
    primaryBorderColor: "#459FFE",
    secondaryColor: "#2A3A4A",
    secondaryTextColor: "#FCFCFC",
    secondaryBorderColor: "#6C7A89",
    tertiaryColor: "#262626",
    tertiaryTextColor: "#FCFCFC",
    tertiaryBorderColor: "#555555",
    lineColor: "#B0B0B0",
    textColor: "#FCFCFC",
    mainBkg: "#2E2E2E",
    nodeBorder: "#459FFE",
    clusterBkg: "#2A2A2A",
    clusterBorder: "#555555",
    edgeLabelBackground: "#222222",
    noteBkgColor: "#3A3424",
    noteTextColor: "#FCFCFC",
    noteBorderColor: "#8A7A4A",
    actorBkg: "#2E2E2E",
    actorBorder: "#459FFE",
    actorTextColor: "#FCFCFC",
    signalColor: "#B0B0B0",
    signalTextColor: "#FCFCFC"
  }
});

let sequence = 0;

window.orbRender = async (kind, source, scale) => {
  const stage = document.getElementById("stage");
  stage.innerHTML = "";
  stage.style.zoom = 1;
  try {
    if (kind === "math") {
      katex.render(source, stage, { displayMode: true, throwOnError: true, trust: false, strict: "ignore", maxSize: 40, maxExpand: 1000 });
    } else {
      sequence += 1;
      const { svg } = await mermaid.render("orb" + sequence, source);
      stage.innerHTML = svg;
    }
    // A web font starts loading at the first layout, so `ready` alone could answer before it began.
    void stage.offsetWidth;
    await document.fonts.ready;
    await new Promise((resolve) => setTimeout(resolve, 30));
    const box = stage.getBoundingClientRect();
    stage.style.zoom = scale;
    return { width: Math.ceil(box.width), height: Math.ceil(box.height) };
  } catch (error) {
    stage.innerHTML = "";
    return { error: String((error && error.message) || error).slice(0, 300) };
  }
};
