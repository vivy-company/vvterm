import React from "react";
import { createRoot } from "react-dom/client";
import { PrivacyPage } from "../pages";
import "../index.css";

function start() {
  const root = createRoot(document.getElementById("root")!);
  root.render(<PrivacyPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
