import { describe } from '@ohos/hypium'

export default function TimeUtilTest() {
  describe('time format', () => {
    const miliseconds = 46613
    const totalSeconds = Math.floor(miliseconds / 1000)
    const totalMinutes = Math.floor(miliseconds / 1000 / 60)
    const totalHours = Math.floor(miliseconds / 1000 / 60 / 60)
    const countsByUnitAsc = [totalSeconds, totalHours]
    let result = ''
    if (totalSeconds > 0) {
      const seconds = totalSeconds % 60

    }
  })
}