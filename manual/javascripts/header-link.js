// Make the site title in the header link home.
//
// Material wraps the logo in an anchor but leaves the title beside it as a bare
// span, so half of what reads as one lockup is clickable and half is not.
//
// Done here rather than by overriding partials/header.html: that partial is
// ~100 lines of Jinja and overriding it means inheriting its maintenance on
// every Material release, for one anchor. This targets two stable class names
// instead, and if it ever stops matching, the result is the current behaviour
// rather than a broken header.
//
// The href is read off the logo anchor rather than computed, so it stays correct
// at any directory depth and under any site_url.

document$.subscribe(function () {
  var topic = document.querySelector(
    ".md-header__title .md-header__topic:first-child .md-ellipsis"
  );
  var logo = document.querySelector(".md-header a.md-logo");

  // Instant navigation re-runs this; bail if the link is already there.
  if (!topic || !logo || topic.querySelector("a.md-header__topic-link")) {
    return;
  }

  var link = document.createElement("a");
  link.href = logo.getAttribute("href");
  link.className = "md-header__topic-link";
  link.title = topic.textContent.trim();

  // Move the text inside the anchor, keeping the span so Material's ellipsis
  // truncation still applies.
  while (topic.firstChild) {
    link.appendChild(topic.firstChild);
  }
  topic.appendChild(link);
});
