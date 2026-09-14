// Oh My Pi extension: same as pi/seh.ts with Oh My Pi's stop event.
// Session ids in the agent's shell (OMP_SESSION_ID) come from the omp-shell-context plugin.
import { sehExtension } from "./seh.ts";

export default sehExtension({ omp: true });
