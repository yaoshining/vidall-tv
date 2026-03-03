import { describe, it, expect } from '@ohos/hypium';
import { parseFileName } from '../main/ets/lib/ScrapeClient';

export default function ScrapeClientTest() {
  describe('parseFileName', () => {

    it('should parse simple movie filename', 0, () => {
      const result = parseFileName('Inception.2010.1080p.BluRay.mkv');
      expect(result.title).assertEqual('Inception');
      expect(result.year).assertEqual(2010);
      expect(result.mediaType).assertEqual('movie');
    });

    it('should parse complex filename and remove quality markers', 0, () => {
      const result = parseFileName('The.Matrix.10bit.X.7.1.mkv');
      expect(result.title).assertEqual('The Matrix');
      expect(result.year).assertEqual(undefined);
      expect(result.mediaType).assertEqual('movie');
    });

  });
}
