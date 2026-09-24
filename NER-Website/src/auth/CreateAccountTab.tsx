import { useState } from "react";
import { EyeIcon, EyeOffIcon, MapPinIcon, BuildingIcon, RadarIcon, ChevronDownIcon } from "./Icons";
import { NER_STATE_DISTRICTS, NER_STATES } from "../data/nerStateDistricts";
import { EMAIL_PATTERN, signUp } from "@/lib/auth";

type Role = "field-officer" | "district-officer" | "control-room" | null;

const ROLES: {
  id: Role;
  label: string;
  descriptor: string;
  Icon: React.FC;
}[] = [
  {
    id: "field-officer",
    label: "Field Officer",
    descriptor: "Ground reporting, route planning, incident logging.",
    Icon: MapPinIcon,
  },
  {
    id: "district-officer",
    label: "District Officer",
    descriptor: "District-level connectivity oversight and reporting review.",
    Icon: BuildingIcon,
  },
  {
    id: "control-room",
    label: "Control Room",
    descriptor: "Region-wide monitoring, fleet tracking, alert broadcast.",
    Icon: RadarIcon,
  },
];

export default function CreateAccountTab() {
  const [showPassword, setShowPassword] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [selectedRole, setSelectedRole] = useState<Role>(null);
  const [selectedState, setSelectedState] = useState("");
  const [selectedDistrict, setSelectedDistrict] = useState("");
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [department, setDepartment] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState<null | { needsConfirmation: boolean; needsApproval: boolean }>(null);

  const isOfficer = selectedRole === "field-officer" || selectedRole === "district-officer";
  const canSubmit = selectedRole !== null && fullName.trim() !== "" && email.trim() !== "" &&
    (selectedRole === "control-room" || (selectedState !== "" && selectedDistrict !== ""));

  if (submitted) {
    return (
      <div className="flex flex-col items-center gap-3 text-center" style={{ fontFamily: "'Noto Sans', sans-serif" }}>
        <p className="text-sm font-semibold" style={{ color: "#1E6B45" }}>
          {submitted.needsConfirmation
            ? "Account created. Confirm your email address using the link we sent you, then log in."
            : "Account created successfully. You can now log in."}
          {submitted.needsApproval && (selectedRole === "field-officer"
            ? " Your account will be activated after approval by your District Officer or the Control Room."
            : " Your account will be activated after approval by the Control Room.")}
        </p>
      </div>
    );
  }

  return (
    <form
      className="flex flex-col gap-5"
      onSubmit={async (e) => {
        e.preventDefault();
        if (!canSubmit || !selectedRole || isSubmitting) return;
        setError(null);
        if (!EMAIL_PATTERN.test(email.trim())) {
          setError("Enter a valid official email address.");
          return;
        }
        if (password.length < 8) {
          setError("Password must be at least 8 characters.");
          return;
        }
        if (password !== confirmPassword) {
          setError("Passwords do not match.");
          return;
        }
        setIsSubmitting(true);
        const result = await signUp({
          email,
          password,
          fullName,
          role: selectedRole === "field-officer" ? "field" : selectedRole === "district-officer" ? "district" : "control",
          state: isOfficer ? selectedState : undefined,
          district: isOfficer ? selectedDistrict : undefined,
          department,
        });
        setIsSubmitting(false);
        if (!result.ok) {
          setError(result.message);
          return;
        }
        setSubmitted({ needsConfirmation: result.needsConfirmation, needsApproval: selectedRole !== "control-room" });
      }}
      style={{ fontFamily: "'Noto Sans', sans-serif" }}
    >
      {/* Full Name */}
      <Field label="Full Name" htmlFor="full-name">
        <input
          id="full-name"
          type="text"
          value={fullName}
          onChange={(e) => setFullName(e.target.value)}
          placeholder="As per official records"
          className="glass-field accent-green"
        />
      </Field>

      {/* Official Email / Employee ID */}
      <Field label="Official Email / Employee ID" htmlFor="official-email">
        <input
          id="official-email"
          type="text"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="officer@gov.in or employee ID"
          className="glass-field accent-green"
        />
      </Field>

      {/* Password */}
      <Field label="Department" htmlFor="department">
        <input
          id="department"
          type="text"
          value={department}
          onChange={(e) => setDepartment(e.target.value)}
          placeholder="Department or division"
          className="glass-field accent-green"
        />
      </Field>

      {/* Password */}
      <Field label="Password" htmlFor="new-password">
        <div className="relative">
          <input
            id="new-password"
            type={showPassword ? "text" : "password"}
            autoComplete="new-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="Minimum 8 characters"
            className="glass-field accent-green has-toggle"
          />
          <PasswordToggle show={showPassword} onToggle={() => setShowPassword((v) => !v)} label="new password" />
        </div>
      </Field>

      {/* Confirm Password */}
      <Field label="Confirm Password" htmlFor="confirm-password">
        <div className="relative">
          <input
            id="confirm-password"
            type={showConfirm ? "text" : "password"}
            autoComplete="new-password"
            value={confirmPassword}
            onChange={(e) => setConfirmPassword(e.target.value)}
            placeholder="Re-enter password"
            className="glass-field accent-green has-toggle"
          />
          <PasswordToggle show={showConfirm} onToggle={() => setShowConfirm((v) => !v)} label="confirm password" />
        </div>
      </Field>

      {/* Role Selection */}
      <fieldset className="flex flex-col gap-2" style={{ border: "none", padding: 0, margin: 0 }}>
        <legend
          className="text-xs font-medium uppercase tracking-wide mb-1"
          style={{ fontFamily: "'Public Sans', sans-serif", color: "#5B6472", letterSpacing: "0.06em" }}
        >
          Select Your Role
        </legend>
        {ROLES.map(({ id, label, descriptor, Icon }) => {
          const active = selectedRole === id;
          return (
            <label
              key={id}
              className={`flex items-start gap-3 px-3 py-3 cursor-pointer transition-colors ${
                active ? "" : "glass-field"
              }`}
              style={{
                border: active
                  ? "1px solid #1E6B45"
                  : "1px solid rgba(91,100,114,0.3)",
                borderRadius: "4px",
                // Selected: solid green-tinted panel. Unselected: glass.
                backgroundColor: active ? "#E9F1EC" : undefined,
                padding: "12px",
                width: "100%",
              }}
            >
              {/* Radio */}
              <div className="flex-shrink-0 mt-0.5">
                <input
                  type="radio"
                  name="role"
                  value={id!}
                  checked={active}
                  onChange={() => {
                    setSelectedRole(id);
                    if (id === "control-room") {
                      setSelectedState("");
                      setSelectedDistrict("");
                    }
                  }}
                  className="sr-only"
                />
                <div
                  className="w-4 h-4 rounded-full border-2 flex items-center justify-center"
                  style={{
                    borderColor: active ? "#1E6B45" : "rgba(91,100,114,0.5)",
                  }}
                >
                  {active && (
                    <div
                      className="w-2 h-2 rounded-full"
                      style={{ backgroundColor: "#1E6B45" }}
                    />
                  )}
                </div>
              </div>

              {/* Icon */}
              <div
                className="flex-shrink-0 mt-0.5"
                style={{ color: active ? "#1E6B45" : "#5B6472" }}
              >
                <Icon />
              </div>

              {/* Text */}
              <div className="flex flex-col gap-0.5">
                <span
                  className="text-sm font-medium"
                  style={{
                    fontFamily: "'Public Sans', sans-serif",
                    color: "#0E2A47",
                  }}
                >
                  {label}
                </span>
                <span
                  className="text-xs leading-relaxed"
                  style={{ color: "#5B6472", fontFamily: "'Noto Sans', sans-serif" }}
                >
                  {descriptor}
                </span>
              </div>
            </label>
          );
        })}
      </fieldset>

      {isOfficer && (
        <>
          {/* State */}
          <Field label="State" htmlFor="state">
            <div className="relative">
              <select
                id="state"
                value={selectedState}
                onChange={(e) => {
                  setSelectedState(e.target.value);
                  setSelectedDistrict("");
                }}
                className="glass-field accent-green has-toggle appearance-none"
              >
                <option value="" disabled>
                  Select State
                </option>
                {NER_STATES.map((s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ))}
              </select>
              <span
                className="absolute right-3 top-1/2 -translate-y-1/2 pointer-events-none"
                style={{ color: "#5B6472" }}
              >
                <ChevronDownIcon />
              </span>
            </div>
          </Field>

          {/* District */}
          <Field label="District" htmlFor="district">
            <div className="relative">
              <select
                id="district"
                value={selectedDistrict}
                onChange={(e) => setSelectedDistrict(e.target.value)}
                disabled={!selectedState}
                className="glass-field accent-green has-toggle appearance-none"
                style={!selectedState ? { opacity: 0.6, cursor: "not-allowed" } : undefined}
              >
                <option value="" disabled>
                  {selectedState ? "Select District" : "Select State First"}
                </option>
                {selectedState &&
                  (NER_STATE_DISTRICTS[selectedState] || []).map((d) => (
                    <option key={d} value={d}>
                      {d}
                    </option>
                  ))}
              </select>
              <span
                className="absolute right-3 top-1/2 -translate-y-1/2 pointer-events-none"
                style={{ color: "#5B6472" }}
              >
                <ChevronDownIcon />
              </span>
            </div>
          </Field>
        </>
      )}

      {error && (
        <p role="alert" className="text-xs rounded px-3 py-2"
          style={{ background: "rgba(179,38,30,0.08)", color: "#B3261E", border: "1px solid rgba(179,38,30,0.25)" }}>
          {error}
        </p>
      )}

      {/* Submit */}
      <button
        type="submit"
        disabled={!canSubmit || isSubmitting}
        className="w-full py-2.5 text-sm font-semibold transition-colors mt-1"
        style={{
          backgroundColor: canSubmit ? "#0E2A47" : "rgba(91,100,114,0.25)",
          color: canSubmit ? "#ffffff" : "#5B6472",
          borderRadius: "4px",
          border: canSubmit ? "1px solid #0E2A47" : "1px solid rgba(91,100,114,0.25)",
          fontFamily: "'Public Sans', sans-serif",
          cursor: canSubmit ? "pointer" : "not-allowed",
          letterSpacing: "0.01em",
        }}
        onMouseEnter={(e) => {
          if (canSubmit) e.currentTarget.style.backgroundColor = "#1B3F63";
        }}
        onMouseLeave={(e) => {
          if (canSubmit) e.currentTarget.style.backgroundColor = "#0E2A47";
        }}
      >
        {isSubmitting ? "Creating account..." : "Create Account"}
      </button>

      <p
        className="text-xs text-center leading-relaxed"
        style={{ color: "#5B6472", fontFamily: "'Noto Sans', sans-serif" }}
      >
        Field Officer and District Officer accounts are activated after approval.
      </p>
    </form>
  );
}

function Field({
  label,
  htmlFor,
  children,
}: {
  label: string;
  htmlFor: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <label
        htmlFor={htmlFor}
        className="text-xs font-medium uppercase tracking-wide"
        style={{ fontFamily: "'Public Sans', sans-serif", color: "#5B6472", letterSpacing: "0.06em" }}
      >
        {label}
      </label>
      {children}
    </div>
  );
}

function PasswordToggle({
  show,
  onToggle,
  label,
}: {
  show: boolean;
  onToggle: () => void;
  label: string;
}) {
  return (
    <button
      type="button"
      onClick={onToggle}
      className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center justify-center"
      style={{ color: "#5B6472", background: "none", border: "none", cursor: "pointer", padding: "2px" }}
      aria-label={show ? `Hide ${label}` : `Show ${label}`}
    >
      {show ? <EyeOffIcon /> : <EyeIcon />}
    </button>
  );
}
