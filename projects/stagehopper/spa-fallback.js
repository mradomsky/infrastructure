// Viewer-request function on the S3 (site) behaviour only — never on /api/*.
//
// The SvelteKit build is a single-page app (`adapter-static`, `fallback: index.html`): every
// deep link such as /festival/{id} or /admin/users must be answered with index.html and
// routed in the browser. The origin is a private S3 bucket behind OAC, which has no
// index-document behaviour, so those URLs miss in S3.
//
// This used to be handled by two distribution-wide `custom_error_response` blocks turning
// every 403 and 404 into `200 /index.html`. CloudFront applies those to every behaviour,
// /api/* included, so an unwired or failing API route answered `200 text/html` instead of
// its real status — the root cause behind the app repo's CLAUDE.md trap 1 and
// mradomsky/stagehopper#181. Rewriting the URI here, before the cache lookup, serves the
// shell for app routes only; a missing file, a missing /data/* object and every /api/*
// error keep their real status.
//
// Rule: a request whose last path segment has no dot is an app route and becomes
// /index.html. Anything with an extension (/_app/*.js, /data/**/*.json, /sw.js,
// /favicon.svg, /manifest.webmanifest) and anything under /data/ is a file and passes
// through untouched. App route segments therefore must not contain a dot (festival ids and
// user-facing slugs don't).
function handler(event) {
	var request = event.request;
	var uri = request.uri;

	if (uri.indexOf('/data/') === 0 || uri.indexOf('/_app/') === 0) {
		return request;
	}

	var last = uri.slice(uri.lastIndexOf('/') + 1);
	if (last.indexOf('.') === -1) {
		request.uri = '/index.html';
	}

	return request;
}
