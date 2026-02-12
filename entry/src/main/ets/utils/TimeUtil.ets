export function millisecondsToTime(milliseconds: number): string {
  const seconds = Math.floor(milliseconds / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const remainingSeconds = seconds % 60;
  const remainingMinutes = minutes % 60;
  let formattedTime =
    `${remainingMinutes.toString().padStart(2, '0')}:${remainingSeconds.toString()
      .padStart(2, '0')}`;
  if (hours > 0) {
    formattedTime = `${hours.toString().padStart(2, '0')}:${formattedTime}`
  }
  return formattedTime;
}