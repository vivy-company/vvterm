import { serve } from "bun";
import index from "./index.html";
import privacy from "./privacy/index.html";
import terms from "./terms/index.html";
import refund from "./refund/index.html";
import thanks from "./thanks/index.html";

const server = serve({
  port: 8787,
  routes: {
    "/": index,
    "/privacy": privacy,
    "/terms": terms,
    "/refund": refund,
    "/thanks": thanks,
    "/robots.txt": Bun.file("./src/robots.txt"),
    "/sitemap.xml": Bun.file("./src/sitemap.xml"),
  },

  development: process.env.NODE_ENV !== "production" && {
    hmr: true,
    console: true,
  },
});

console.log(`Server running at ${server.url}`);
