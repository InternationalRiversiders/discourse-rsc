# Vendored browser libraries

`rsc-three-0.186.1-b2.js` is a tree-shaken, minified ES module build of
[three.js](https://threejs.org/) 0.186.1 (MIT, see the `-b2.LICENSE.txt` file).
It is loaded at runtime only on the games page by
`assets/javascripts/discourse/lib/game-3d.js`.

Rebuild after using a new `THREE.X` name in `lib/game-3d-scenes.js`:

```sh
npm pack three@0.186.1 && tar xzf three-0.186.1.tgz
names=$(grep -o '\bT\.[A-Z][A-Za-z0-9]*' assets/javascripts/discourse/lib/game-3d-scenes.js | sed 's/T\.//' | sort -u | paste -sd, -)
echo "export { $names } from './package/build/three.module.js';" > entry.js
npx esbuild@0.25.10 entry.js --bundle --format=esm --minify --legal-comments=eof --outfile=public/javascripts/rsc-three-0.186.1-b2.js
```

Keep the version in the file name and bump the `-bN` build suffix (and `THREE_PATH`) for any rebuild so
browsers never combine a cached library with newer scene code.
