import type { Role } from '@/roles';

export interface ProfileMeta {
  label: string;
  profileName: string;
  profileInitials: string;
  officerId: string;
  department: string;
  region: string;
  state?: string;
  district?: string;
  phone: string;
  email: string;
  lastLogin: string;
  status: string;
  avatarUrl?: string;
}

const STORAGE_KEY = 'ner-profile';
const SESSION_KEY = 'ner-session-role';
const ACCOUNTS_KEY = 'ner-accounts';
const CURRENT_USER_KEY = 'ner-current-user-email';

// Neutral placeholders per role, shown only until the signed-in account's profile loads.
const DEFAULT_PROFILES: Record<Role, ProfileMeta> = {
  control: {
    label: 'Control Officer', profileName: 'Control Officer', profileInitials: 'CO', officerId: '', department: '',
    region: 'North Eastern Region', phone: '', email: '', lastLogin: '', status: 'Active',
  },
  district: {
    label: 'District Officer', profileName: 'District Officer', profileInitials: 'DO', officerId: '', department: '',
    region: '', phone: '', email: '', lastLogin: '', status: 'Active',
  },
  field: {
    label: 'Field Officer', profileName: 'Field Officer', profileInitials: 'FO', officerId: '', department: '',
    region: '', phone: '', email: '', lastLogin: '', status: 'Active',
  },
};

class ProfileService {
  private listeners: Set<(profile: ProfileMeta) => void> = new Set();
  private currentProfile: ProfileMeta | null = null;

  // Find an account by email or officer ID
  findAccount(identity: string): ProfileMeta | null {
    if (!identity) return null;
    const key = identity.trim().toLowerCase();
    const accounts = this.loadAccounts();

    // Check registered accounts by email or officerId
    for (const id in accounts) {
      const acc = accounts[id];
      if (
        acc.email.toLowerCase() === key ||
        acc.officerId.toLowerCase() === key ||
        id.toLowerCase() === key
      ) {
        return acc;
      }
    }


    return null;
  }

  // Get current profile with fallback to default
  getProfile(): ProfileMeta {
    if (this.currentProfile) {
      return this.currentProfile;
    }

    const role = this.getCurrentRole();
    if (!role) {
      console.warn('No current role found, returning default district profile');
      return DEFAULT_PROFILES.district;
    }

    try {
      const savedProfile = this.loadFromStorage();
      if (savedProfile) {
        // Ensure profile matches current role
        const profileRole = this.getRoleFromLabel(savedProfile.label);
        if (profileRole === role) {
          this.currentProfile = savedProfile;
          return savedProfile;
        }
      }

      // Check current user key in accounts
      if (typeof window !== 'undefined') {
        const currentUserEmail = window.localStorage.getItem(CURRENT_USER_KEY);
        if (currentUserEmail) {
          const acc = this.findAccount(currentUserEmail);
          if (acc && this.getRoleFromLabel(acc.label) === role) {
            this.currentProfile = acc;
            this.saveToStorage(acc);
            return acc;
          }
        }
      }

      // Return default profile for current role
      this.currentProfile = { ...DEFAULT_PROFILES[role] };
      return this.currentProfile;
    } catch (error) {
      console.error('Error getting profile:', error);
      // Return safe fallback
      return DEFAULT_PROFILES.district;
    }
  }

  // Update profile and notify all listeners
  async updateProfile(updates: Partial<ProfileMeta>): Promise<{ success: boolean; error?: string }> {
    try {
      const currentProfile = this.getProfile();
      
      // Validate required fields
      if (updates.profileName !== undefined && !updates.profileName.trim()) {
        return { success: false, error: 'Name is required' };
      }
      if (updates.email !== undefined && !updates.email.trim()) {
        return { success: false, error: 'Email is required' };
      }
      if (updates.email !== undefined && !this.isValidEmail(updates.email)) {
        return { success: false, error: 'Invalid email format' };
      }
      if (updates.phone !== undefined && updates.phone.trim() && !this.isValidPhone(updates.phone)) {
        return { success: false, error: 'Invalid phone number format' };
      }

      // Handle role change
      if (updates.label && updates.label !== currentProfile.label) {
        const newRole = this.getRoleFromLabel(updates.label);
        if (newRole) {
          this.setSessionRole(newRole);
          // Merge with default profile for new role
          const defaultProfile = DEFAULT_PROFILES[newRole];
          updates = {
            ...defaultProfile,
            ...updates,
            profileInitials: this.generateInitials(updates.profileName || defaultProfile.profileName),
          };
        }
      }

      // Generate initials if name changed
      if (updates.profileName && !updates.profileInitials) {
        updates.profileInitials = this.generateInitials(updates.profileName);
      }

      // Update profile
      const updatedProfile: ProfileMeta = { ...currentProfile, ...updates };
      this.currentProfile = updatedProfile;
      this.saveToStorage(updatedProfile);
      this.saveAccount(updatedProfile);
      
      // Notify all listeners
      this.notifyListeners(updatedProfile);
      
      return { success: true };
    } catch (error) {
      console.error('Profile update failed:', error);
      return { success: false, error: 'Failed to update profile' };
    }
  }

  // Subscribe to profile changes
  subscribe(listener: (profile: ProfileMeta) => void): () => void {
    try {
      this.listeners.add(listener);
      // Immediately call with current profile (if already loaded)
      if (this.currentProfile) {
        listener(this.currentProfile);
      } else {
        // Try to get profile, but don't fail subscription if it errors
        try {
          const currentProfile = this.getProfile();
          if (currentProfile) {
            listener(currentProfile);
          }
        } catch (error) {
          console.error('Error getting initial profile for subscription:', error);
        }
      }
      // Return unsubscribe function
      return () => this.listeners.delete(listener);
    } catch (error) {
      console.error('Error in profile subscription:', error);
      return () => {}; // Return no-op function
    }
  }

  // Get current session role
  getCurrentRole(): Role | null {
    if (typeof window === 'undefined') return null;
    try {
      return window.localStorage.getItem(SESSION_KEY) as Role | null;
    } catch {
      return null;
    }
  }

  // Set session role
  setSessionRole(role: Role): void {
    if (typeof window === 'undefined') return;
    try {
      if (!role || !['field', 'district', 'control'].includes(role)) {
        console.error('Invalid role provided to setSessionRole:', role);
        return;
      }
      window.localStorage.setItem(SESSION_KEY, role);
      // Reset current profile to force reload with new role
      this.currentProfile = null;
      this.notifyListeners(this.getProfile());
    } catch (error) {
      console.error('Failed to set session role:', error);
    }
  }

  // Adopt a profile loaded from Supabase. The database role is authoritative.
  adoptProfile(profile: ProfileMeta, role: Role): void {
    this.currentProfile = profile;
    this.saveToStorage(profile);
    if (typeof window !== 'undefined') {
      window.localStorage.setItem(SESSION_KEY, role);
      window.localStorage.setItem(CURRENT_USER_KEY, profile.email.toLowerCase());
    }
    this.notifyListeners(profile);
  }

  // Clear session (preserves saved user accounts dictionary)
  clearSession(): void {
    if (typeof window === 'undefined') return;
    try {
      window.localStorage.removeItem(SESSION_KEY);
      window.localStorage.removeItem(STORAGE_KEY);
      window.localStorage.removeItem(CURRENT_USER_KEY);
      this.currentProfile = null;
    } catch (error) {
      console.error('Failed to clear session:', error);
    }
  }

  // Private methods
  private loadFromStorage(): ProfileMeta | null {
    if (typeof window === 'undefined') return null;
    try {
      const data = window.localStorage.getItem(STORAGE_KEY);
      return data ? JSON.parse(data) : null;
    } catch {
      return null;
    }
  }

  private saveToStorage(profile: ProfileMeta): void {
    if (typeof window === 'undefined') return;
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(profile));
    } catch (error) {
      console.error('Failed to save profile:', error);
    }
  }

  private loadAccounts(): Record<string, ProfileMeta> {
    if (typeof window === 'undefined') return {};
    try {
      const data = window.localStorage.getItem(ACCOUNTS_KEY);
      return data ? JSON.parse(data) : {};
    } catch {
      return {};
    }
  }

  private saveAccount(profile: ProfileMeta): void {
    if (typeof window === 'undefined') return;
    try {
      const accounts = this.loadAccounts();
      if (profile.email) {
        accounts[profile.email.toLowerCase()] = profile;
      }
      if (profile.officerId) {
        accounts[profile.officerId.toLowerCase()] = profile;
      }
      window.localStorage.setItem(ACCOUNTS_KEY, JSON.stringify(accounts));
    } catch (error) {
      console.error('Failed to save account:', error);
    }
  }

  private notifyListeners(profile: ProfileMeta): void {
    this.listeners.forEach(listener => {
      try {
        listener(profile);
      } catch (error) {
        console.error('Profile listener error:', error);
      }
    });
  }

  public getRoleFromLabel(label: string): Role | null {
    const normalized = label.toLowerCase();
    if (normalized.includes('field')) return 'field';
    if (normalized.includes('control')) return 'control';
    if (normalized.includes('district')) return 'district';
    return null;
  }

  private generateInitials(name: string): string {
    return name
      .trim()
      .split(/\s+/)
      .map(part => part[0])
      .join('')
      .slice(0, 2)
      .toUpperCase();
  }

  private isValidEmail(email: string): boolean {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    return emailRegex.test(email);
  }

  private isValidPhone(phone: string): boolean {
    // Allow various phone formats
    const phoneRegex = /^[\d\s\+\-\(\)]{10,}$/;
    return phoneRegex.test(phone.replace(/\s/g, ''));
  }
}

// Export singleton instance
export const profileService = new ProfileService();
