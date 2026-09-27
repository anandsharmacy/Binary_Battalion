// Field officers see the same live public.alerts feed as other officers (RLS decides visibility).
// The old incidents/tasks-derived view read localStorage and was removed with the alert pipeline.
export { default } from '@/pages/Alerts';
