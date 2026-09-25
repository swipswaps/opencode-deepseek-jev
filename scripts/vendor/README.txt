vendor/ — pinned third-party assets served by the dashboard
============================================================

d3.min.js
    D3 v7.9.0 (https://d3js.org), ISC license, Copyright 2010-2023 Mike
    Bostock. Pulled from https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js
    and vendored so the charts work offline and the version is pinned.
    Served by dashboard.mjs at /vendor/d3.min.js.

d3-sankey.min.js
    d3-sankey v0.12.3 (https://github.com/d3/d3-sankey), ISC license,
    Copyright 2019 Mike Bostock. Pulled from
    https://cdn.jsdelivr.net/npm/d3-sankey@0.12.3/dist/d3-sankey.min.js.
    Attaches d3.sankey / d3.sankeyLinkHorizontal to the global d3.
    Served at /vendor/d3-sankey.min.js.

To refresh:
    curl -s -o scripts/vendor/d3.min.js \
      https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js
    curl -s -o scripts/vendor/d3-sankey.min.js \
      https://cdn.jsdelivr.net/npm/d3-sankey@0.12.3/dist/d3-sankey.min.js
    # then update the versions above and re-run ./scripts/test-dashboard.sh
