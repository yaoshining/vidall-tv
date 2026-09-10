import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';

export function readTestParameter(parameters: Record<string, string>, key: string, fallback: string): string {
  const value = parameters[key] ?? parameters[`-s ${key}`];
  return value !== undefined && String(value).length > 0 ? String(value) : fallback;
}

export function getTestParameter(key: string, fallback: string): string {
  const parameters = abilityDelegatorRegistry.getArguments().parameters as Record<string, string>;
  return readTestParameter(parameters, key, fallback);
}
