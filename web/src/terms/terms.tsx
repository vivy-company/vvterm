import React from "react";
import { createRoot } from "react-dom/client";
import { TermsPage } from "../pages";
import "../index.css";

function start() {
  const root = createRoot(document.getElementById("root")!);
  root.render(<TermsPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
