import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
// tool/email_corpus/collect/lib -> repo root
export const REPO_ROOT = path.resolve(here, '..', '..', '..', '..');
export const STORE_DIR = path.join(REPO_ROOT, '.email_test_store', 'corpus');
export const RAW_DIR = path.join(STORE_DIR, '_raw');
export const PILOT_DIR = path.join(STORE_DIR, 'pilot');
export const COLLECT_DIR = path.resolve(here, '..');
