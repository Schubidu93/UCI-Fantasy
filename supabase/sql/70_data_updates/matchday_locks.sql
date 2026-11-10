update matchdays set locked = true where not locked and waivers_done and deadline <= now();

