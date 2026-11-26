import { cp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const source = dirname(fileURLToPath(import.meta.url));
if (!process.argv[2]) throw Error('Pass the destination game asset directory.');
const destination = resolve(process.argv[2]);
if (destination === source) throw Error('Choose an export directory outside the source.');
await mkdir(destination, { recursive: true });
for (const name of await readdir(source)) {
  if (name.endsWith('.js') || name === 'game.css' || name === 'art' || name === 'music') {
    await cp(join(source, name), join(destination, name), { recursive: true, dereference: true });
  }
}
const html = await readFile(join(source, 'index.html'), 'utf8');
await writeFile(join(destination, 'index.html'), html.replace('🟠 Keyboard Ninja', 'Keyboard Ninja'));
