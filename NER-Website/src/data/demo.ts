export type Severity = 'CRITICAL' | 'HIGH' | 'MODERATE' | 'LOW';
export type IncidentStatus = 'PENDING_VERIFICATION' | 'ACTIVE' | 'ESCALATED' | 'RESOLVED' | 'UNDER_REVIEW';
export type IncidentType = 'Flood' | 'Landslide' | 'Road Blockage' | 'Accident' | 'Infrastructure Damage' | 'Vehicle Breakdown';
export type RouteStatus = 'Open' | 'Restricted' | 'Blocked' | 'Closed';
export type OfficerStatus = 'Available' | 'On Task' | 'Emergency' | 'Offline';
export type TaskStatus = 'New' | 'In Progress' | 'Completed' | 'Escalated' | 'Awaiting Verification' | 'Verified' | 'Rejected';

export interface IncidentEvidence {
  name: string;
  type: string;
  size: number;
  dataUrl: string;
}

export interface Incident {
  id: string;
  type: IncidentType;
  location: string;
  route: string;
  severity: Severity;
  reportedBy: string;
  reportedTime: string;
  /** ISO timestamp of the report; `reportedTime` is only the display string. */
  reportedAt?: string;
  verification: 'Pending' | 'Verified' | 'Rejected';
  assignedOfficer: string | null;
  status: IncidentStatus;
  description: string;
  gpsCoords: string;
  riskScore: number;
  affectedLogistics: number;
  estimatedDisruption: string;
  evidence?: IncidentEvidence[];
}

export interface Route {
  id: string;
  name: string;
  distance: string;
  accessibilityScore: number;
  riskScore: number;
  status: RouteStatus;
  weather: string;
  eta: string;
  delay: string;
  floodRisk: Severity;
  landslideRisk: Severity;
  lastUpdated: string;
  incidents: number;
}

export interface Vehicle {
  id: string;
  cargo: string;
  origin: string;
  destination: string;
  currentLocation: string;
  route: string;
  eta: string;
  delay: string;
  risk: Severity;
  status: 'On Time' | 'Delayed' | 'At Risk' | 'Stopped';
}

export interface FieldOfficer {
  id: string;
  name: string;
  location: string;
  currentTask: string | null;
  status: OfficerStatus;
  lastUpdate: string;
  avgResponseTime: string;
  assignedIncidents: number;
}

export interface Task {
  id: string;
  title: string;
  location: string;
  priority: Severity;
  assignedOfficer: string | null;
  created: string;
  deadline: string;
  status: TaskStatus;
  relatedIncident: string | null;
  description: string;
  /** District Officer's rejection reason, shown to the Field Officer. */
  verificationNote?: string;
  /** ISO timestamps used for Avg Response Time. */
  assignedAt?: string;
  startedAt?: string;
  completedAt?: string;
}

export interface Alert {
  id: string;
  severity: Severity;
  category: string;
  title: string;
  location: string;
  time: string;
  description: string;
  source: string;
  acknowledged: boolean;
}

export const incidents: Incident[] = [];

export const routes: Route[] = [];

export const vehicles: Vehicle[] = [];

export const fieldOfficers: FieldOfficer[] = [];

export const tasks: Task[] = [];

export const alerts: Alert[] = [];

export const aiInsights = {
  riskPredictions: [],
  logisticsPredictions: [],
  routeRecommendations: [],
  resourceRecommendations: [],
};
