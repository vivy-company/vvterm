import React from "react";
import { createRoot } from "react-dom/client";
import { ThanksPage } from "../pages";
import "../index.css";

function start() {
  const root = createRoot(document.getElementById("root")!);
  root.render(<ThanksPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
