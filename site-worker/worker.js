// healthaccessmcp.com: static files from dist/site (see scripts/build-site.sh), served by
// Workers static assets. This script sends http and www to https://healthaccessmcp.com and
// adds security headers (HSTS, a strict CSP: the site runs no scripts).
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol === "http:" || url.hostname === "www.healthaccessmcp.com") {
      url.protocol = "https:";
      url.hostname = "healthaccessmcp.com";
      return Response.redirect(url.toString(), 301);
    }
    const response = await env.ASSETS.fetch(request);
    const headers = new Headers(response.headers);
    headers.set("X-Content-Type-Options", "nosniff");
    headers.set("Referrer-Policy", "no-referrer");
    headers.set("Permissions-Policy", "interest-cohort=()");
    headers.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
    headers.set("X-Frame-Options", "DENY");
    headers.set(
      "Content-Security-Policy",
      "default-src 'self'; script-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    );
    if (url.pathname.endsWith(".txt")) headers.set("Content-Type", "text/plain; charset=utf-8");
    if (url.pathname.endsWith(".md")) headers.set("Content-Type", "text/markdown; charset=utf-8");
    if (url.pathname.startsWith("/fonts/")) headers.set("Cache-Control", "public, max-age=31536000, immutable");
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  },
};
