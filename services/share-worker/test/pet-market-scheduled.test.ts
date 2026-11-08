import { expect, it, vi } from 'vitest';

const publications = vi.hoisted(() => ({ plugin: vi.fn(), companion: vi.fn() }));
vi.mock('../src/market', async importOriginal => ({
  ...await importOriginal<typeof import('../src/market')>(),
  publishMarket: publications.plugin,
}));
vi.mock('../src/pet-market', async importOriginal => ({
  ...await importOriginal<typeof import('../src/pet-market')>(),
  publishPetMarket: publications.companion,
}));
import worker from '../src/index';
import { makeEnv } from './fakes';

it('waits for companion publication before reporting an independent plugin failure', async () => {
  const failure = new Error('synthetic plugin storage failure');
  const pending = Promise.withResolvers<void>();
  publications.plugin.mockRejectedValueOnce(failure);
  publications.companion.mockReturnValueOnce(pending.promise);
  const { env } = makeEnv({ PET_MARKET_ENABLED: '1' });
  const scheduled = worker.scheduled({} as ScheduledController, env);
  let settled = false;
  const observed = scheduled.then(() => { settled = true; }, () => { settled = true; });
  await vi.waitFor(() => expect(publications.companion).toHaveBeenCalledOnce());
  // Allow the rejected plugin promise to propagate through a fail-fast join.
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(settled).toBe(false);
  pending.resolve();
  await expect(scheduled).rejects.toBe(failure);
  await observed;
});
