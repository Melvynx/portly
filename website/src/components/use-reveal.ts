import { useEffect } from "react";

/*
 * Reveals every [data-reveal] element the first time it scrolls into view.
 *
 * The hidden state lives behind .js-reveal on <html>, which is only added
 * here, on the client: without JavaScript the page renders as static HTML with
 * nothing invisible. Reduced motion is handled in CSS rather than by skipping
 * the observer, so those users still get the fade without the travel.
 */
export function useReveal() {
  useEffect(() => {
    const targets = document.querySelectorAll<HTMLElement>("[data-reveal]");

    if (!("IntersectionObserver" in window)) {
      targets.forEach((element) => element.classList.add("is-in"));
      return;
    }

    document.documentElement.classList.add("js-reveal");

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          entry.target.classList.add("is-in");
          observer.unobserve(entry.target);
        }
      },
      /* A little short of the bottom edge, so nothing animates half off-screen. */
      { rootMargin: "0px 0px -10% 0px", threshold: 0.05 },
    );

    targets.forEach((element) => observer.observe(element));

    return () => {
      observer.disconnect();
      document.documentElement.classList.remove("js-reveal");
    };
  }, []);
}
