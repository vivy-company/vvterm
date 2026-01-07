import React from "react";
import { createRoot } from "react-dom/client";
import { RefundPage } from "../pages";
import "../index.css";

function start() {
  const root = createRoot(document.getElementById("root")!);
  root.render(<RefundPage />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
