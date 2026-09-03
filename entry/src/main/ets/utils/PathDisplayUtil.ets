export function truncateMiddlePath(path: string, maxLen: number): string {
  if (path.length === 0) {
    return '';
  }
  if (path.length <= maxLen) {
    return path;
  }

  const segments: string[] = path.split('/');
  const nonEmpty: string[] = segments.filter((seg: string): boolean => seg.length > 0);

  if (nonEmpty.length < 2) {
    const tail: string = nonEmpty.length === 1 ? nonEmpty[0] : '';
    if (tail.length <= maxLen) {
      return path;
    }
    const keepTail: number = maxLen - 1;
    if (keepTail <= 0) {
      return '…';
    }
    return '…' + tail.substring(tail.length - keepTail);
  }

  const first: string = nonEmpty[0];
  const second: string = nonEmpty[1];
  const last: string = nonEmpty[nonEmpty.length - 1];

  const head: string = '/' + first + '/' + second;
  const resultHead2: string = head + '/…/' + last;
  if (resultHead2.length <= maxLen) {
    return resultHead2;
  }

  const resultHead1: string = '/' + first + '/…/' + last;
  if (resultHead1.length <= maxLen) {
    return resultHead1;
  }

  const prefix: string = '/…/';
  const availableForTail: number = maxLen - prefix.length;
  if (availableForTail <= 0) {
    return '…' + last.substring(last.length - Math.max(1, maxLen - 1));
  }
  if (last.length <= availableForTail) {
    return prefix + last;
  }
  const tailKeep: number = availableForTail;
  return '…' + last.substring(last.length - tailKeep);
}
